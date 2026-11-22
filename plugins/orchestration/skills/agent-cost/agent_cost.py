#!/usr/bin/env python3
"""Per-agent token/cost rollup for Claude Code subagent transcripts.

Sums the four usage counters (input, cache-write, cache-read, output) across
every response row in each subagent's transcript, prices them per-model, and
prints a table sorted by cost descending. Stdlib only.

Usage:
    python3 agent_cost.py [SESSION_DIR_OR_TRANSCRIPT] [--json]

With no argument, auto-resolves the current project's newest session under
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<slug-of-cwd>/, where the slug
rule replaces every non-alphanumeric character in the absolute cwd with '-'.
"""

import argparse
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Pricing table.
#
# Source: the `claude-api` skill's cached "Current Models" pricing table
# (cache date 2026-06-24), read via the Skill tool on 2026-07-15 while
# building this tool. Dollars per million tokens.
#
# cache_write / cache_read are not published as flat per-model dollar
# figures — they are documented as multipliers of the model's input price
# (shared/prompt-caching.md): cache read ~0.1x input, cache write 1.25x
# input for the default 5-minute TTL (2x for a 1-hour TTL, which this table
# does not attempt to distinguish — the four usage counters in a transcript
# don't carry TTL information either). Values below are computed from that
# multiplier, not independently published, so treat them as a good estimate
# rather than an exact invoice figure.
#
# claude-sonnet-5 is priced at its INTRODUCTORY rate ($2/$10 per MTok),
# active through 2026-08-31 per the skill. After that date it reverts to
# $3/$15 (cache_write $3.75, cache_read $0.30) — update this row then.
#
# REVIEW THIS TABLE whenever new models ship or pricing windows lapse.
PRICING_PER_MILLION_USD = {
    "claude-fable-5": {
        "input": 10.00, "output": 50.00, "cache_write": 12.50, "cache_read": 1.00,
    },
    "claude-mythos-5": {
        "input": 10.00, "output": 50.00, "cache_write": 12.50, "cache_read": 1.00,
    },
    "claude-opus-5-5": {
        # Verified 2026-09-29 against platform.claude.com/docs/en/about-claude/pricing:
        # cache hits are 0.05x input on Opus 5.5 (not the usual 0.1x).
        "input": 4.00, "output": 20.00, "cache_write": 5.00, "cache_read": 0.20,
    },
    "claude-sonnet-5-5": {
        # Cache reads cut from $0.20 to $0.10 (0.05x input) on 2026-10-07; verified
        # 2026-10-23 against the pricing page and the release notes. A transcript
        # from before the cut is understated on cache reads by half.
        "input": 2.00, "output": 10.00, "cache_write": 2.50, "cache_read": 0.10,
    },
    "claude-opus-5": {
        # Verified 2026-09-04 against platform.claude.com/docs/en/about-claude/pricing.
        "input": 5.00, "output": 25.00, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-8": {
        "input": 5.00, "output": 25.00, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-7": {
        "input": 5.00, "output": 25.00, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-6": {
        "input": 5.00, "output": 25.00, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-sonnet-5": {
        # $2/$10 was announced as introductory through 2026-08-31 but is now the STANDARD price —
        # the scheduled rise to $3/$15 on 2026-09-01 was cancelled (verified 2026-09-04 on
        # platform.claude.com pricing). No revert needed.
        "input": 2.00, "output": 10.00, "cache_write": 2.50, "cache_read": 0.20,
    },
    "claude-sonnet-4-6": {
        "input": 3.00, "output": 15.00, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-haiku-5-5": {
        # Priced by prompt length: an API response whose prompt (input + cache read
        # + cache write) is over 100,000 tokens bills every counter at the
        # long_prompt rates. Verified 2026-10-23 against the pricing page.
        "input": 0.10, "output": 0.50, "cache_write": 0.125, "cache_read": 0.01,
        "long_prompt": {
            "threshold": 100_000,
            "input": 0.50, "output": 2.50, "cache_write": 0.625, "cache_read": 0.05,
        },
    },
    "claude-haiku-4-5": {
        "input": 1.00, "output": 5.00, "cache_write": 1.25, "cache_read": 0.10,
    },
}

AGENT_STEM_RE = re.compile(r"^agent-(?P<id>.+)$")


@dataclass
class AgentUsage:
    agent_stem: str
    name: Optional[str] = None
    description: Optional[str] = None
    input_tokens: int = 0
    cache_write_tokens: int = 0
    cache_read_tokens: int = 0
    output_tokens: int = 0
    model_counts: Counter = field(default_factory=Counter)
    # The share of each counter from API responses over their model's long-prompt
    # threshold, keyed like the rate table ("input", "cache_write", ...).
    long_prompt_tokens: Counter = field(default_factory=Counter)
    parse_errors: int = 0
    api_calls: int = 0        # distinct message.id values billed
    duplicate_rows: int = 0   # rows skipped as re-logs of an already-counted response

    @property
    def total_tokens(self) -> int:
        return (
            self.input_tokens
            + self.cache_write_tokens
            + self.cache_read_tokens
            + self.output_tokens
        )

    @property
    def primary_model(self) -> Optional[str]:
        if not self.model_counts:
            return None
        return self.model_counts.most_common(1)[0][0]

    @property
    def display_name(self) -> str:
        if self.name:
            return self.name
        if self.description:
            return self.description
        return self.agent_stem

    def cost_usd(self):
        """Returns (cost_or_None, note_or_None)."""
        if self.total_tokens == 0:
            return 0.0, None
        model = self.primary_model
        rates = PRICING_PER_MILLION_USD.get(model) if model else None
        if rates is None:
            return None, f"unpriced model: {model!r}"
        long_rates = rates.get("long_prompt")
        long = self.long_prompt_tokens if long_rates else Counter()
        totals = {
            "input": self.input_tokens,
            "cache_write": self.cache_write_tokens,
            "cache_read": self.cache_read_tokens,
            "output": self.output_tokens,
        }
        cost = sum(
            (tokens - long[k]) * rates[k] + long[k] * (long_rates or rates)[k]
            for k, tokens in totals.items()
        ) / 1_000_000.0
        return cost, None


def load_meta(meta_path: str, stem: str):
    """Returns (name, description). Never raises."""
    if not os.path.isfile(meta_path):
        return None, None
    try:
        with open(meta_path, "r", encoding="utf-8") as fh:
            meta = json.load(fh)
        if not isinstance(meta, dict):
            return None, None
        return meta.get("name"), meta.get("description")
    except Exception:
        return None, None


def parse_transcript(jsonl_path: str, usage: AgentUsage) -> None:
    """Sum the usage counters ONCE PER API RESPONSE. Skips bad lines.

    Deduplicated by `message.id`, and that is the whole correctness story here.
    A Claude Code transcript writes the SAME assistant response to disk more
    than once (verified: identical `message.id` AND byte-identical `usage`
    dicts on separate rows). A row-by-row sum therefore bills one API call
    several times.

    This is not hypothetical -- it shipped. The naive sum reported an agent at
    118.1M tokens against a true 62.9M, and priced an 11-agent session at
    $147.87 when a whole-session tool said $99.38. The part exceeding the whole
    is what exposed it.

    Worse, the "frozen number" this tool was built to reproduce (input=32774,
    cache_read=201313) was itself produced by a naive sum -- inflated 225% --
    so reproducing it EXACTLY was proof of nothing except that the bug had been
    copied faithfully. A frozen anchor only verifies what was independently
    verified first.

    `usage.api_calls` / `usage.duplicate_rows` are kept so the dedup stays
    visible and auditable rather than being a silent correction.
    """
    try:
        fh = open(jsonl_path, "r", encoding="utf-8")
    except Exception as exc:
        usage.parse_errors += 1
        print(f"warning: could not open {jsonl_path}: {exc}", file=sys.stderr)
        return
    seen_ids = set()
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                usage.parse_errors += 1
                continue
            message = row.get("message") if isinstance(row, dict) else None
            if not isinstance(message, dict):
                continue
            row_usage = message.get("usage")
            if not isinstance(row_usage, dict):
                continue
            # Fall back to the row uuid when a response carries no id: a row we
            # cannot key is counted once rather than dropped (under-reporting a
            # cost is as wrong as over-reporting it).
            msg_id = message.get("id") or row.get("uuid")
            if msg_id is not None:
                if msg_id in seen_ids:
                    usage.duplicate_rows += 1
                    continue
                seen_ids.add(msg_id)
            usage.api_calls += 1
            counts = {
                "input": int(row_usage.get("input_tokens") or 0),
                "cache_write": int(row_usage.get("cache_creation_input_tokens") or 0),
                "cache_read": int(row_usage.get("cache_read_input_tokens") or 0),
                "output": int(row_usage.get("output_tokens") or 0),
            }
            usage.input_tokens += counts["input"]
            usage.cache_write_tokens += counts["cache_write"]
            usage.cache_read_tokens += counts["cache_read"]
            usage.output_tokens += counts["output"]
            model = message.get("model")
            if model:
                usage.model_counts[model] += 1
            long_rates = PRICING_PER_MILLION_USD.get(model, {}).get("long_prompt")
            prompt = counts["input"] + counts["cache_write"] + counts["cache_read"]
            if long_rates and prompt > long_rates["threshold"]:
                usage.long_prompt_tokens.update(counts)


def collect_agents(subagents_dir: str):
    """Returns a list of AgentUsage, one per agent-*.jsonl found."""
    agents = []
    try:
        entries = sorted(os.listdir(subagents_dir))
    except Exception as exc:
        print(f"error: could not list {subagents_dir}: {exc}", file=sys.stderr)
        return agents
    for entry in entries:
        if not entry.endswith(".jsonl"):
            continue
        if not entry.startswith("agent-"):
            continue
        stem = entry[: -len(".jsonl")]
        jsonl_path = os.path.join(subagents_dir, entry)
        meta_path = os.path.join(subagents_dir, stem + ".meta.json")
        name, description = load_meta(meta_path, stem)
        usage = AgentUsage(agent_stem=stem, name=name, description=description)
        parse_transcript(jsonl_path, usage)
        agents.append(usage)
    return agents


def slugify_cwd(cwd: str) -> str:
    """Claude Code's project-dir slug rule: every non-alphanumeric char -> '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def find_newest_session_subagents_dir(project_dir: str):
    """Returns (subagents_dir, session_id) for the most recently touched
    session under project_dir that has a subagents/ directory, or
    (None, None) if none qualify."""
    best_path = None
    best_session = None
    best_mtime = -1.0
    try:
        entries = os.scandir(project_dir)
    except Exception:
        return None, None
    with entries as it:
        for entry in it:
            if not entry.is_dir(follow_symlinks=True):
                continue
            sub = os.path.join(entry.path, "subagents")
            if not os.path.isdir(sub):
                continue
            mtime = os.path.getmtime(sub)
            try:
                for fname in os.listdir(sub):
                    fpath = os.path.join(sub, fname)
                    try:
                        m = os.path.getmtime(fpath)
                        if m > mtime:
                            mtime = m
                    except OSError:
                        continue
            except OSError:
                pass
            if mtime > best_mtime:
                best_mtime = mtime
                best_path = sub
                best_session = entry.name
    return best_path, best_session


def resolve_subagents_dir(path_arg: Optional[str]):
    """Returns (subagents_dir_or_None, message_or_None, fatal_bool).

    fatal_bool True means the caller should exit non-zero; False with a
    None dir means a clean "nothing to report" exit at status 0.
    """
    if path_arg is None:
        config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
            os.path.expanduser("~"), ".claude"
        )
        slug = slugify_cwd(os.getcwd())
        project_dir = os.path.join(config_dir, "projects", slug)
        if not os.path.isdir(project_dir):
            return (
                None,
                f"no project directory found for this cwd (looked under {project_dir})",
                True,
            )
        sub, session_id = find_newest_session_subagents_dir(project_dir)
        if sub is None:
            return (
                None,
                f"no session under {project_dir} has a subagents/ directory",
                False,
            )
        return sub, f"(auto-resolved session {session_id})", False

    if not os.path.exists(path_arg):
        return None, f"path does not exist: {path_arg}", True
    if not os.path.isdir(path_arg):
        return None, f"path is not a directory: {path_arg}", True

    base = os.path.basename(os.path.normpath(path_arg))
    try:
        listing = os.listdir(path_arg)
    except Exception as exc:
        return None, f"could not list {path_arg}: {exc}", True

    if base == "subagents" or any(
        f.startswith("agent-") and f.endswith(".jsonl") for f in listing
    ):
        return path_arg, None, False

    sub = os.path.join(path_arg, "subagents")
    if os.path.isdir(sub):
        return sub, None, False

    return None, f"no subagents/ directory found under {path_arg}", False


def format_table(agents, unpriced_notes):
    if not agents:
        return "No agent transcripts found."

    def sort_key(a: AgentUsage):
        cost, _ = a.cost_usd()
        return (cost is None, -(cost or 0.0))

    ordered = sorted(agents, key=sort_key)

    name_w = max(8, min(32, max(len(a.display_name) for a in ordered)))
    model_w = max(5, min(20, max(len(a.primary_model or "unknown") for a in ordered)))

    header = (
        f"{'AGENT':<{name_w}}  {'MODEL':<{model_w}}  {'INPUT':>10}  "
        f"{'CACHE_W':>10}  {'CACHE_R':>10}  {'OUTPUT':>10}  {'TOTAL_TOK':>11}  {'COST_USD':>10}"
    )
    lines = [header, "-" * len(header)]

    total_input = total_cw = total_cr = total_out = total_tok = 0
    total_cost = 0.0
    any_unpriced = False

    for a in ordered:
        cost, note = a.cost_usd()
        model = a.primary_model or "unknown"
        if len(model) > model_w:
            model = model[: model_w - 1] + "…"
        name = a.display_name
        if len(name) > name_w:
            name = name[: name_w - 1] + "…"
        cost_str = f"${cost:,.4f}" if cost is not None else "unknown"
        lines.append(
            f"{name:<{name_w}}  {model:<{model_w}}  {a.input_tokens:>10,}  "
            f"{a.cache_write_tokens:>10,}  {a.cache_read_tokens:>10,}  "
            f"{a.output_tokens:>10,}  {a.total_tokens:>11,}  {cost_str:>10}"
        )
        if a.model_counts and len(a.model_counts) > 1:
            variants = ", ".join(f"{m}={c}" for m, c in a.model_counts.most_common())
            lines.append(f"{'':<{name_w}}    (model varies across turns: {variants})")
        if note:
            lines.append(f"{'':<{name_w}}    ({note})")
            any_unpriced = True

        total_input += a.input_tokens
        total_cw += a.cache_write_tokens
        total_cr += a.cache_read_tokens
        total_out += a.output_tokens
        total_tok += a.total_tokens
        if cost is not None:
            total_cost += cost

    lines.append("-" * len(header))
    lines.append(
        f"{'TOTAL':<{name_w}}  {'':<{model_w}}  {total_input:>10,}  "
        f"{total_cw:>10,}  {total_cr:>10,}  {total_out:>10,}  {total_tok:>11,}  "
        f"${total_cost:,.4f}"
    )
    if any_unpriced:
        lines.append(
            "(TOTAL excludes agents with an unpriced model — see notes above)"
        )
    return "\n".join(lines)


def to_json_obj(agents):
    out = []
    for a in agents:
        cost, note = a.cost_usd()
        out.append(
            {
                "agent": a.agent_stem,
                "name": a.name,
                "description": a.description,
                "model": a.primary_model,
                "model_counts": dict(a.model_counts),
                "input_tokens": a.input_tokens,
                "cache_write_tokens": a.cache_write_tokens,
                "cache_read_tokens": a.cache_read_tokens,
                "output_tokens": a.output_tokens,
                "total_tokens": a.total_tokens,
                "cost_usd": cost,
                "unpriced_note": note,
                "parse_errors_skipped": a.parse_errors,
            }
        )
    priced_total = sum(r["cost_usd"] for r in out if r["cost_usd"] is not None)
    return {
        "agents": sorted(
            out, key=lambda r: (r["cost_usd"] is None, -(r["cost_usd"] or 0.0))
        ),
        "total_cost_usd": priced_total,
        "unpriced_agents": [r["agent"] for r in out if r["unpriced_note"]],
    }


def _selftest_usage_counted_once_per_api_response() -> int:
    """One API response must be billed ONCE, however many rows it occupies.

    Asserts BEHAVIOUR, not the presence of dedup code: it feeds a transcript in
    which one response is logged three times (the real shape on disk — same
    message.id, identical usage) plus one genuinely distinct response, and
    checks the arithmetic. It FAILS against the pre-fix parser, which is the
    only property that makes it worth having: a naive sum reports 400 input
    tokens here, the truth is 200.
    """
    import tempfile

    dup = {"type": "assistant", "message": {"id": "msg_dup", "model": "claude-sonnet-5",
           "usage": {"input_tokens": 100, "cache_creation_input_tokens": 10,
                     "cache_read_input_tokens": 1000, "output_tokens": 5}}}
    uniq = {"type": "assistant", "message": {"id": "msg_uniq", "model": "claude-sonnet-5",
            "usage": {"input_tokens": 100, "cache_creation_input_tokens": 10,
                      "cache_read_input_tokens": 1000, "output_tokens": 5}}}
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for row in (dup, dup, dup, uniq):     # 4 rows, but only 2 API calls
            fh.write(json.dumps(row) + "\n")
        path = fh.name
    try:
        u = AgentUsage(agent_stem="selftest")
        parse_transcript(path, u)
        checks = [
            ("input_tokens", u.input_tokens, 200),      # naive sum would say 400
            ("cache_read_tokens", u.cache_read_tokens, 2000),
            ("output_tokens", u.output_tokens, 10),
            ("api_calls", u.api_calls, 2),
            ("duplicate_rows", u.duplicate_rows, 2),
        ]
        failed = [(n, got, want) for n, got, want in checks if got != want]
        for name, got, want in checks:
            print(f"  {'ok  ' if got == want else 'FAIL'} {name}: got {got}, want {want}")
        if failed:
            print("SELFTEST FAILED — one API response is being billed more than once")
            return 1
        print("selftest passed: usage is counted once per API response")
        return 0
    finally:
        os.unlink(path)


def _selftest_long_prompt_responses_priced_at_long_rates() -> int:
    """A Haiku 5.5 response over 100k prompt tokens bills at 5x; one under does not.

    Two responses with the same counters except cache reads: one at exactly
    100,000 prompt tokens (short rates), one a token over (long rates).
    """
    import tempfile

    def row(msg_id, cache_read):
        return {"type": "assistant", "message": {"id": msg_id, "model": "claude-haiku-5-5",
                "usage": {"input_tokens": 1_000, "cache_creation_input_tokens": 1_000,
                          "cache_read_input_tokens": cache_read, "output_tokens": 2_000}}}

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        fh.write(json.dumps(row("short", 98_000)) + "\n")
        fh.write(json.dumps(row("long", 98_001)) + "\n")
        path = fh.name
    try:
        u = AgentUsage(agent_stem="selftest")
        parse_transcript(path, u)
        got, _ = u.cost_usd()
        short = (1_000 * 0.10 + 1_000 * 0.125 + 98_000 * 0.01 + 2_000 * 0.50) / 1e6
        long = (1_000 * 0.50 + 1_000 * 0.625 + 98_001 * 0.05 + 2_000 * 2.50) / 1e6
        ok = abs(got - (short + long)) < 1e-12
        print(f"  {'ok  ' if ok else 'FAIL'} haiku-5-5 cost: got {got:.9f}, want {short + long:.9f}")
        if not ok:
            print("SELFTEST FAILED — long-prompt responses are not priced at long-prompt rates")
            return 1
        print("selftest passed: long-prompt responses are priced at long-prompt rates")
        return 0
    finally:
        os.unlink(path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Per-agent token/cost rollup for Claude Code subagent transcripts."
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=None,
        help="A session directory (containing subagents/), or a subagents/ "
        "directory directly. Omit to auto-resolve the current project's "
        "newest session.",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    parser.add_argument("--selftest", action="store_true",
                        help="Run the dedup regression test and exit.")
    args = parser.parse_args(argv)

    if args.selftest:
        return (_selftest_usage_counted_once_per_api_response()
                or _selftest_long_prompt_responses_priced_at_long_rates())

    subagents_dir, message, fatal = resolve_subagents_dir(args.path)
    if subagents_dir is None:
        print(message or "no subagents directory resolved.", file=sys.stderr)
        return 1 if fatal else 0

    if message and not args.json:
        print(message, file=sys.stderr)

    agents = collect_agents(subagents_dir)

    if not agents:
        if args.json:
            print(json.dumps({"agents": [], "total_cost_usd": 0.0, "unpriced_agents": []}))
        else:
            print(f"No agent-*.jsonl transcripts found under {subagents_dir}")
        return 0

    if args.json:
        print(json.dumps(to_json_obj(agents), indent=2))
    else:
        print(format_table(agents, None))
    return 0


if __name__ == "__main__":
    sys.exit(main())
