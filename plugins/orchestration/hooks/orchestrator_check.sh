#!/usr/bin/env bash
# UserPromptSubmit hook — orchestrator reflex primer.
#
# Fires on every user prompt. Its plain stdout is injected into the model's
# context BEFORE the prompt is processed, so the orchestration policy is
# front-of-mind at the exact moment the request is decomposed — surviving the
# mid-session drift that a once-at-startup CLAUDE.md read cannot.
#
# It does NOT teach orchestration (CLAUDE.md + ~/.claude/model-routing-policy.md
# + the installed skills do that) — it only FIRES it, routing into whichever
# mechanism already exists. Keep it short: every token here is paid per turn.
#
# SLIMMED 2026-07-16 (~510 -> ~100 tokens/turn): the long form restated the
# CLAUDE.md section nearly verbatim into the SAME context — the main thread
# already carries CLAUDE.md, and subagents see neither (UserPromptSubmit never
# fires for them; their channel is the dispatch brief). Measured cost of the
# duplication: ~50k tokens of context window per 100-turn run — window occupancy
# is what triggers checkpoints/compaction, so it was the scarcest thing being
# spent. What remains below is the firing pin, not the doctrine.
#
# In cages it is seeded into each cage's settings.json by _ccage_pre_exec_hook
# in ~/.bashrc.d/claude-overrides.sh (fixed path, so it never bashes the prompt
# cache); outside cages it is registered in ~/.claude/settings.json directly.
#
# Always exits 0 — a UserPromptSubmit hook must never block the user's prompt.
# No `set -e`: a hiccup should no-op, not abort the turn.

cat <<'EOF'
[orchestrator gate] Decompose BEFORE acting; fan out only when it pays (money or wall-clock: >=2 independent units with real volume -> ONE dispatch message, cheapest sufficient tiers). INDEPENDENT = DISJOINT WRITE SETS — fan out on compute, serialise writes through the root. A plan/design doc in play -> READ it (RESUME summaries are pointers, not the plan) and act as DISPATCHER: dependency waves, never sequential inline execution. Name every agent; stop them ALL before /clear or compaction. Never assert an unverified external fact — verify first or label it assumption. The binding doctrine is CLAUDE.md "Orchestration & model routing" + ~/.claude/model-routing-policy.md; budget every workflow, state cost before large fan-outs.
EOF
exit 0
