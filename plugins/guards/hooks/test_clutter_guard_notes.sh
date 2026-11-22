#!/usr/bin/env bash
# Exercises clutter_guard.sh's notes-organisation rules. Each case asserts the
# exit code. The fixture tree lives under $HOME, not /tmp, because the guard
# deliberately allows every /tmp and scratchpad path before it checks notes.
#   bash ~/.claude/hooks/test_clutter_guard_notes.sh          # expect all PASS
#   CCLAUDE_CLUTTER_MODE=off bash ~/.claude/hooks/test_clutter_guard_notes.sh
#                                                              # expect the blocks to FAIL
set -u
HOOK="$(dirname "$(readlink -f "$0")")/clutter_guard.sh"
T=$(mktemp -d "$HOME/.cache/clutter-guard-fixture.XXXXXX")
trap 'rm -rf "$T"' EXIT

R="$T/repo"
mkdir -p "$R/notes/design/rollout_model_change" "$R/notes/research/investigation" "$R/src/pkg" \
         "$R/notes/design/rollouts/four_rollout_models_on_lorenz96_and_ring/artefacts"
echo '{}' > "$R/notes/design/rollouts/four_rollout_models_on_lorenz96_and_ring/study.json"
echo legacy > "$R/notes/design/rollout_model_change/results_task14_w4s.md"
S="$R/notes/design/rollouts/four_rollout_models_on_lorenz96_and_ring"

run() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
FAILED=0
check() {
  got=$(run "$2")
  if [ "$got" = "$3" ]; then echo "  PASS  $1 (exit $got)"; else echo "  FAIL  $1 (expected $3, got $got)"; FAILED=1; fi
}

echo "structure"
check "loose file at notes/design root"            "$R/notes/design/new_plan.md" 2
check "README at notes/design root is allowed"     "$R/notes/design/README.md" 0
check "loose file in a programme folder"           "$R/notes/design/rollouts/summary.md" 2
check "loose file in a legacy folder"              "$R/notes/design/rollout_model_change/summary_of_models.md" 2
check "study folder without study.json"            "$R/notes/design/rollouts/anchor_points_vs_autoregressive/results.md" 2
check "study.json itself is allowed"               "$R/notes/design/rollouts/anchor_points_vs_autoregressive/study.json" 0
check "content in a study with study.json"         "$S/rollout_trained_model_from_scratch.md" 0
check "artefact in a study with study.json"        "$S/artefacts/error_by_lead.csv" 0
echo "names"
check "task number in a new note"                  "$S/results_task14.md" 2
check "work-item code in a new note"               "$S/results_w4s.md" 2
check "decision id in a new note"                  "$S/followup_d165.md" 2
check "task code in a new research note"           "$R/notes/research/investigation/T5_9_readout.md" 2
check "item code in a new artefact"                "$S/artefacts/a4_2_scores.csv" 2
check "arm label in a new note"                    "$S/arm_b_recipe.md" 2
check "new study folder with a code"               "$R/notes/design/rollouts/task14/study.json" 2
check "new study folder with a weekend date"       "$R/notes/design/rollouts/weekend_2026-09-05/study.json" 2
check "new study folder with a date only"          "$R/notes/design/rollouts/rollouts_2026-09-15/study.json" 2
echo "allowed"
check "overwrite of an existing legacy file"       "$R/notes/design/rollout_model_change/results_task14_w4s.md" 0
check "code names outside notes/ are not policed"  "$R/src/pkg/task14_cells.py" 0
check "descriptive name with system tags (gs64)"   "$S/gs64_and_ad64_error_comparison.md" 0
check "descriptive name with lorenz96 / e2e"       "$S/lorenz96_e2e_check.md" 0
check "dated file name is allowed"                 "$S/summary_2026-09-15.md" 0

[ "$FAILED" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
