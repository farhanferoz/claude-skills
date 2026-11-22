---
name: agent-cost
description: >-
  Roll up per-subagent token usage and USD cost from Claude Code transcripts.
  Use when asked "what did that fan-out cost", "how much did agent X burn",
  "break down spend by subagent", or before/after a large delegation to check
  whether it paid off. Fills a real gap: an orchestrator otherwise cannot see
  what its own subagents cost, so "budget every fan-out" is unenforceable.
---

# Agent cost — per-subagent token/cost rollup

An orchestrator that fans out to subagents has no visibility into what those
subagents actually spent — `tokenol` and similar tools roll up by *session*,
which mixes the parent thread's tokens in with every child's. This skill
answers the narrower question: **which subagent cost what, in this session.**

## When to use

- After a fan-out, to check whether delegation actually saved money (or to
  catch one worker that burned far more than its siblings).
- Before stopping/cleaning up orphaned agents, to see what they already cost.
- Any time the user asks for a cost or token breakdown *by agent* rather than
  by session or by day.

Not a replacement for `tokenol` — use `tokenol sessions` / `daily` / `live`
for whole-session or whole-day totals. This tool is subagent-scoped only: its
total for a session will always be *less* than tokenol's total for the same
session, because tokenol also counts the parent thread's own tokens.

## Usage

```sh
python3 ${CLAUDE_SKILL_DIR}/agent_cost.py                    # auto-resolve current project's newest session
python3 ${CLAUDE_SKILL_DIR}/agent_cost.py <session-dir>      # a session dir containing subagents/
python3 ${CLAUDE_SKILL_DIR}/agent_cost.py <subagents-dir>    # or the subagents/ dir directly
python3 ${CLAUDE_SKILL_DIR}/agent_cost.py <session-dir> --json
```

With no argument, it resolves
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<slug-of-cwd>/` and picks the
most recently touched session that has a `subagents/` directory — i.e. the
session you're most likely asking about right now.

Output is a table sorted by cost descending (agent name, model, input,
cache-write, cache-read, output, total tokens, cost), plus a TOTAL row.
`--json` emits the same data as JSON for piping into other tooling.

## What it does

For every `agent-*.jsonl` transcript in the `subagents/` directory, it sums
the four usage counters (`input_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `output_tokens`) across every response row, reads
`name`/`description` from the sibling `.meta.json` for identity (falling
back to the filename if the meta is missing or corrupt), and prices the
total against a per-model rate table.

**Unknown model id → the cost is reported as `unknown`/`null`, never
guessed.** A missing number is recoverable; a plausible-looking wrong one
isn't. If you hit this on a model that should be priced, add it to
`PRICING_PER_MILLION_USD` in `agent_cost.py` — get the number from the repo's
verified pricing table or a targeted fetch of the relevant `platform.claude.com`
page, not from memory. (The `claude-api` skill is banned machine-wide: it costs
210–260 k tokens per load. See CLAUDE.md, "No guessing".)

## Companion: `agent_harvest.py` — recover an agent's answer from disk

A subagent's result reaches the orchestrator through the message channel, and
that delivery is **lossy**. Measured 2026-08-22 in one session: of nine
graders, **seven tables never arrived**, including one agent that had
generated 2168 output tokens and another whose recovered verdict changed a
3-1 split into a 3-2 one. The reflex on "the agent returned nothing" is to
re-dispatch, which pays full price for work that is already finished and
already on disk.

Every subagent writes its full transcript to
`<session>/subagents/agent-<id>.jsonl` as it runs. The final assistant text
block IS its return value. So a silent agent is never a reason to re-dispatch
and never a lost result — read it:

```sh
python3 ${CLAUDE_SKILL_DIR}/agent_harvest.py --list        # who answered, who is empty
python3 ${CLAUDE_SKILL_DIR}/agent_harvest.py grader-2      # print that agent's answer
python3 ${CLAUDE_SKILL_DIR}/agent_harvest.py r2- --all-text  # every text block, for split answers
```

Same session resolution and same name lookup as `agent_cost.py`. `--list`
first: it shows `ANSWER PRESENT` or `EMPTY` per agent, which distinguishes
"the delivery was lost" from "the agent genuinely produced nothing".

**Check this before spawning any replacement agent.** It is also why a
fan-out of three is usually enough: the reason to over-provision was never
disagreement, it was the fear of losing votes, and that fear is now cheap to
resolve.

## Known limitations

- Cache-write/cache-read rates are computed from the published multipliers
  (write ≈1.25× input at the default 5-minute TTL, read ≈0.1× input) since
  Anthropic doesn't publish flat per-model dollar figures for them, and the
  four usage counters don't distinguish 5-minute vs 1-hour TTL. Treat costs
  as a close estimate, not an exact invoice reconciliation.
- `claude-sonnet-5` is priced at its introductory rate, active only through
  2026-08-31 — the pricing table has a comment marking where to revert it.
- This is a read-only, on-demand report. It does not watch, alert, or hook
  into anything — run it whenever you want a snapshot.
