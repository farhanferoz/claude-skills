---
name: second-opinion
description: "Runs an external LLM code review on uncommitted changes, branch diffs, or specific commits. Auto-discovers installed CLIs (agy / codex / gemini-cli) per ~/.claude/second-opinion.config.json. Use when the user asks for a second opinion, external review, codex review, gemini review, agy review, antigravity review, or mentions /second-opinion."
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - AskUserQuestion
---

# Second Opinion

Shell out to an external LLM CLI for an independent code review. The skill
reads `~/.claude/second-opinion.config.json` to decide which CLI to use
and which model to pass.

## Config

`~/.claude/second-opinion.config.json` (required):

```json
{
  "preferred_order": ["agy", "codex", "gemini-cli"],
  "models": {
    "agy": "Gemini 3.5 Pro",
    "codex": "gpt-5.3-codex",
    "gemini-cli": "gemini-3.1-pro-preview"
  }
}
```

- `preferred_order` — tools to try in priority order.
- `models.<tool>` — model identifier for that tool. Format is CLI-specific
  (display string for agy, model ID for codex/gemini-cli).

To change the default tool or model, edit this file. Per-project overrides
are not supported — open an issue if you need them.

Adding a new CLI requires editing this skill (each CLI needs its own
invocation branch with the right flags and stdin handling) plus a new
entry in the config.

## Pipeline

### 1. Pick the tool

```bash
CONFIG=~/.claude/second-opinion.config.json
TOOL=""
for t in $(jq -r '.preferred_order[]' "$CONFIG"); do
  command -v "$t" >/dev/null 2>&1 && { TOOL="$t"; break; }
done
[ -z "$TOOL" ] && { echo "No configured CLI installed"; exit 1; }
MODEL=$(jq -r ".models.\"$TOOL\"" "$CONFIG")
```

### 2. Gather scope + focus

One `AskUserQuestion`, skip questions the user already answered inline.

**Scope:**
- Uncommitted — `git diff HEAD` + untracked
- Branch diff — `git diff <base>...HEAD` (auto-detect base via
  `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'`)
- Specific commit — `git diff <sha>~1..<sha>`

**Project context** (only if `./CLAUDE.md` or `./AGENTS.md` exists):
- Include it / standard review

**Focus:**
- General / Security & auth / Performance / Error handling

### 3. Build prompt + diff

```bash
DIFF=/tmp/second-opinion-diff.txt
PROMPT=/tmp/second-opinion-prompt.txt
git diff <scope> > "$DIFF"  # plus untracked if uncommitted

# Stop if empty. HARD CAP ~1500 lines: agy/gemini truncate large stdin and
# then improvise (read disk, roam) instead of reviewing. Over the cap, split
# into multiple smaller invocations rather than sending one giant prompt.

{
  printf '%s\n' "Independent code review. Report findings by severity (critical/high/medium/low/info) with file:line. Describe each finding's failure mode. Do not propose fixes. Review ONLY the text provided below — do NOT read files from disk, edit files, or run commands (tests, builds, linters, git). If the provided text looks truncated, say so and review what you have; do NOT go looking for the rest. Trust any test/lint pass claims in the project context."
  printf '\nProject root: %s\n' "$(pwd)"
  [ -f CLAUDE.md ] && [ "$INCLUDE_CONTEXT" = "yes" ] && { printf '\n\nProject conventions:\n```\n'; cat CLAUDE.md; printf '\n```\n'; }
  [ -n "$FOCUS" ] && printf '\n\nFocus area: %s\n' "$FOCUS"
  printf '\n\nDiff:\n```diff\n'
  cat "$DIFF"
  printf '\n```\n'
} > "$PROMPT"
```

### 4. Invoke the selected tool

Each tool has its own branch — the CLI surfaces differ enough that a
generic template doesn't work.

**Isolation (agy, gemini-cli):** these run with `--dangerously-skip-permissions` / `--yolo`, so they CAN write files and drop scratch dirs (e.g. `.antigravitycli/`). Invoke them from a throwaway cwd — `(cd "$(mktemp -d)" && <cli> < "$PROMPT")` — so nothing lands in the repo. The prompt is referenced by absolute path, so cwd doesn't matter to the review. (codex already runs `--sandbox read-only`.) After the run, verify the repo is untouched: `git -C <repo> status --porcelain` should show only your own pre-existing changes.

#### agy

agy has no `--model` flag — model is read from
`~/.gemini/antigravity-cli/settings.json`. The skill saves the current
model, writes the configured one, runs agy, and restores the original
via a bash `trap` that fires on EXIT/INT/TERM. The user's interactive
agy state is left exactly as it was.

The entire block below MUST run inside a single Bash tool invocation —
the trap is process-local. Set Bash tool `timeout: 600000` (10 min);
SIGTERM from a timeout still triggers the trap.

```bash
SETTINGS=~/.gemini/antigravity-cli/settings.json

# Snapshot current model so we can restore it on exit.
ORIGINAL=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)

restore_agy_model() {
  # No-op if there was no model to begin with — don't write garbage.
  [ -z "$ORIGINAL" ] && return 0
  jq --arg m "$ORIGINAL" '.model = $m' "$SETTINGS" > "${SETTINGS}.tmp" \
    && mv "${SETTINGS}.tmp" "$SETTINGS"
}
trap restore_agy_model EXIT INT TERM

# Write the configured model only if it differs (avoid no-op write).
if [ "$ORIGINAL" != "$MODEL" ]; then
  jq --arg m "$MODEL" '.model = $m' "$SETTINGS" > "${SETTINGS}.tmp" \
    && mv "${SETTINGS}.tmp" "$SETTINGS"
fi

( cd "$(mktemp -d)" && agy --print --dangerously-skip-permissions --print-timeout 8m < "$PROMPT" )
# Shell exit here fires the EXIT trap → ORIGINAL is restored.
# print-timeout 8m (not 5m): leaves headroom under the 10m Bash cap for a
# full-size review; raise the Bash timeout in lockstep if you raise this.
```

Edge cases handled:
- `ORIGINAL` empty (settings missing/unset) → restore is a no-op, no garbage written.
- `jq` failure → `&&` short-circuits the `mv`, original file untouched.
- agy non-zero exit → EXIT trap still fires.
- Timeout kill (SIGTERM) → TERM trap fires.
- User Ctrl-C (SIGINT) → INT trap fires.
- Concurrent skill invocations → both will race on `${SETTINGS}.tmp`. Not
  protected against; the skill is not designed for parallel use.

#### codex

```bash
codex exec --sandbox read-only --ephemeral --model "$MODEL" - < "$PROMPT"
```

See [references/codex-invocation.md](references/codex-invocation.md) for
the full pattern (structured JSON output, output schema, etc.).

#### gemini-cli

```bash
( cd "$(mktemp -d)" && gemini -p - --yolo -m "$MODEL" < "$PROMPT" )
```

See [references/gemini-invocation.md](references/gemini-invocation.md) for
extension-specific flags.

Set Bash tool `timeout: 600000` (10 min) for all invocations.

### 5. Present findings

Header: `## <Tool> review (<model>)`, then the tool's output. No
cross-summary needed — single tool, single perspective.

## Error Handling

| Error | Action |
|---|---|
| `No configured CLI installed` | List `preferred_order`, suggest installing the first one |
| Empty diff | Stop, tell user |
| Timeout / tool roams + reads disk instead of reviewing | Input was truncated (over the ~1500-line cap) — re-run with a smaller prompt, split if needed |
| agy: print-mode hangs | agy may need interactive login first — run `agy` once interactively |
| Repo dirtied / `.antigravitycli/` appeared after a run | Tool wrote outside its sandbox — you skipped the `(cd "$(mktemp -d)" && …)` isolation; `git restore`/clean and re-run isolated |

## Examples

```
User: /second-opinion
Claude: [reads config, picks agy (first installed), model = Gemini 3.5 Pro]
Claude: [asks scope/context/focus]
User: uncommitted, yes CLAUDE.md, security
Claude: [shows diff --stat]
Claude: [writes Gemini 3.5 Pro to agy settings.json]
Claude: [runs agy --print --dangerously-skip-permissions < prompt]
Claude: [presents findings under "## agy review (Gemini 3.5 Pro)"]
```

```
User: /second-opinion codex performance
Claude: [user specified tool + focus inline; skips those questions]
Claude: [asks scope + context only]
Claude: [runs codex exec --model gpt-5.3-codex]
```
