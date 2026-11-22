#!/usr/bin/env bash
# Self-test for the model-load block of code_hygiene_check.sh (decision D4 of localmodels' measured-settings work).
# Follows the container_lifecycle_guard.selftest.sh convention: drive the hook with real PostToolUse payloads, assert
# what it said and what it logged. Only the model-load block is judged here (its banner on stderr, its tags in the
# log): the other checks of the hook (ruff, dupcheck, GPU free memory, the bypass block) have their own behaviour.
# Run: bash code_hygiene_check.selftest.sh
set -u
HOOK="$(dirname "$0")/code_hygiene_check.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

# Keep the real log out of the way of a test run.
export CLAUDE_CONFIG_DIR="$WORK/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
LOG="$CLAUDE_CONFIG_DIR/code_hygiene_check.log"
BANNER="model load without localmodels' settings lookup"

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

hook() { # hook <file>: run the hook on a file; sets ERR (stderr) and RC
  local payload; payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))' "$1")
  ERR=$(printf '%s' "$payload" | bash "$HOOK" 2>&1 >/dev/null); RC=$?
}

seed() { # seed <relative path> <content>: write a file under $WORK/proj and print its path
  local f="$WORK/proj/$1"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$2" > "$f"; printf '%s' "$f"
}

case_warns() { # case_warns <description> <relative path> <content>
  local f; f=$(seed "$2" "$3"); hook "$f"
  if [ "$RC" -eq 2 ] && grep -qF "$BANNER" <<<"$ERR"; then
    ok "$1"
  else
    fail "$1 (wanted the model-load warning and exit 2, got exit $RC)"
  fi
}

case_quiet() { # case_quiet <description> <relative path> <content>
  local f; f=$(seed "$2" "$3"); hook "$f"
  if grep -qF "$BANNER" <<<"$ERR"; then fail "$1 (warned: $(grep -A1 -F "$BANNER" <<<"$ERR" | tail -1))"; else ok "$1"; fi
}

log_has() { # log_has <description> <tag> <file basename>
  if grep -qE "^[0-9T:-]+ +$2 +$3\$" "$LOG"; then ok "$1"; else fail "$1 (no '$2 $3' line in the log)"; fi
}

echo "code_hygiene_check model-load selftest"

# --- one seeded file per kept pattern must warn -----------------------------------------------------------------
case_warns "1  a model load: AutoModel*.from_pretrained"          scripts/p1_load.py        $'from transformers import AutoModelForCausalLM\nmodel = AutoModelForCausalLM.from_pretrained("org/name")'
case_warns "1  a model load: a class ending in Model"             scripts/p1_peft.py        $'model = PeftModel.from_pretrained(base, "org/adapter")'
case_warns "1  a model load: a multi-line call"                   scripts/p1_multi.py       $'model = AutoModel.from_pretrained(\n    "org/name",\n)'
case_warns "2  a verifier load: SentenceTransformer / CrossEncoder" scripts/p2_embed.py     $'model = SentenceTransformer("org/embedder", device="cuda")'
case_warns "3  in-process llama.cpp: llama_cpp.Llama("             scripts/p3_llama.py       $'import llama_cpp\nllm = llama_cpp.Llama(model_path="m.gguf")'
case_warns "4  the loader keyword torch_dtype="                    scripts/p4_kw.py          $'kwargs = dict(torch_dtype=torch.bfloat16)'
case_warns "4b a precision string dtype=\"bfloat16\""              scripts/p4b_str.py        $'spec = Spec(name="x", dtype="bfloat16")'
case_warns "5  a precision recorded as a literal"                 scripts/p5_record.py      $'meta = {"encoder": "e", "encoder_precision": "fp32"}'
case_warns "7  a llama.cpp flag written by hand"                  scripts/p7_flags.py       $'extra = ("-fa", "on", "--spec-type", "draft-mtp")'
case_warns "7  a micro-batch flag written by hand"                scripts/p7_ub.py          $'args = ["-m", path, "-ub", "2048"]'

# the remedy names the lookup, explicit= and the comment, and never offers a way to switch the hook off
f=$(seed scripts/remedy.py $'model = AutoModel.from_pretrained("org/name")'); hook "$f"
for needle in 'localmodels.settings.lookup(model, kind, engine=...)' 'explicit=' '# localmodels: explicit'; do
  if grep -qF -- "$needle" <<<"$ERR"; then ok "remedy names: $needle"; else fail "remedy is missing: $needle"; fi
done
if grep -qiE 'disable|bypass|skip the hook|HYGIENE_OFF' <<<"$ERR"; then fail "remedy offers an escape hatch"; else ok "remedy offers no way to switch the hook off"; fi

# --- narrowing: what the scan showed to be false alarms must stay quiet -----------------------------------------
case_quiet "a tensor dtype is not a load"                  scripts/n_tensor.py   $'x = torch.zeros(3, dtype=torch.float32)\ny = torch.randn(2, dtype=torch.float64)\nz = idx.to(dtype=torch.long)'
case_quiet "a bare torch.float32 is not a load"            scripts/n_bare.py     $'DTYPE = torch.float32'
case_quiet "a matmul-precision switch is not flagged"      scripts/n_matmul.py   $'torch.set_float32_matmul_precision("highest")\ntorch.backends.cudnn.allow_tf32 = False'
case_quiet "a tokenizer / config / processor load"         scripts/n_tok.py      $'tok = AutoTokenizer.from_pretrained("org/name")\ncfg = AutoConfig.from_pretrained("org/name")\nproc = AutoProcessor.from_pretrained("org/name")'
case_quiet "a project wrapper class call is not a load"    scripts/n_wrap.py     $'scorer = NLIScorer.from_pretrained(name, device)'
case_quiet "a comment or a docstring mention"              scripts/n_doc.py      $'# AutoModel.from_pretrained("org/name") is what the wrapper calls\n"""Loads with `AutoModel.from_pretrained(...)` or SentenceTransformer(...)."""'
case_quiet "numpy dtype strings are not a model precision" scripts/n_np.py       $'a = np.zeros(3, dtype="float32")'

# --- the explicit comment declares a deliberate fixed setting ----------------------------------------------------
case_quiet "a line with the explicit comment is skipped"   scripts/e_one.py      $'model = AutoModel.from_pretrained("org/name")  # localmodels: explicit'
log_has    "the skip is logged as ALLOW-lmlookup-explicit"  ALLOW-lmlookup-explicit e_one.py
case_warns "an explicit line does not cover a second load" scripts/e_two.py      $'a = AutoModel.from_pretrained("org/a")  # localmodels: explicit\nb = AutoModel.from_pretrained("org/b")'

# --- exempt paths: training and research ---------------------------------------------------------------------------
case_quiet "tests/ is exempt"                              tests/x_load.py                     $'m = AutoModel.from_pretrained("org/name")'
case_quiet "training/ is exempt"                           pkg/training/x_load.py              $'m = AutoModel.from_pretrained("org/name")'
case_quiet "research/ is exempt"                           research/x_load.py                  $'m = AutoModel.from_pretrained("org/name")'
case_quiet "planning/ is exempt"                           planning/x_load.py                  $'m = AutoModel.from_pretrained("org/name")'
case_quiet "a train_*.py script is exempt"                 scripts/train_encoders.py           $'m = AutoModel.from_pretrained("org/name")'
case_quiet "a spike_*.py script is exempt"                 scripts/spike_logits.py             $'m = AutoModel.from_pretrained("org/name")'
export CLAUDE_PLUGIN_OPTION_LM_LOOKUP_EXEMPT_GLOBS="*/other-project/*:*/research-project/*"
case_quiet "a project listed in LM_LOOKUP_EXEMPT_GLOBS is exempt" research-project/src/x_load.py $'m = AutoModel.from_pretrained("org/name")'
unset CLAUDE_PLUGIN_OPTION_LM_LOOKUP_EXEMPT_GLOBS
case_warns "the same project is not exempt without the setting" research-project/src/y_load.py $'m = AutoModel.from_pretrained("org/name")'
log_has    "an exempt path is logged as ALLOW-lmlookup-exempt" ALLOW-lmlookup-exempt train_encoders.py

# --- a file that already calls the lookup ----------------------------------------------------------------------------
case_quiet "a file that imports localmodels.settings is left alone" scripts/a_adopted.py \
  $'from localmodels.settings import lookup\nanswer = lookup(model, kind)\nm = AutoModel.from_pretrained("org/name")'
log_has    "that is logged as ALLOW-lmlookup-adopted"       ALLOW-lmlookup-adopted a_adopted.py

# --- a model's own code inside a localmodels server (exempt), and the side that starts one (not exempt) ----------------
case_quiet "a file defining a localmodels ModelServer is left alone" src/pkg/backends/m_served.py \
  $'from localmodels.serving import ModelServer\nclass MServer(ModelServer):\n    def load(self, msg):\n        self.m = AutoModelForCausalLM.from_pretrained(msg.path, dtype=msg.dtype)'
log_has    "that is logged as ALLOW-lmlookup-served"        ALLOW-lmlookup-served m_served.py
case_warns "a file that only imports from localmodels.serving still warns" src/pkg/jobs/m_starter.py \
  $'from localmodels.serving import ModelHost\nm = AutoModel.from_pretrained("org/name")'

# --- only the lines an edit adds are read (git-tracked file) ----------------------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO/scripts"
git -C "$REPO" init -q 2>/dev/null
printf '%s\n' 'old = AutoModel.from_pretrained("org/old")' > "$REPO/scripts/tracked.py"
git -C "$REPO" add scripts/tracked.py
git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qm base 2>/dev/null
hook "$REPO/scripts/tracked.py"
if grep -qF "$BANNER" <<<"$ERR"; then fail "a committed load is not re-flagged on an edit that adds nothing"; else ok "a committed load is not re-flagged on an edit that adds nothing"; fi
printf '%s\n' 'new = AutoModel.from_pretrained("org/new")' >> "$REPO/scripts/tracked.py"
hook "$REPO/scripts/tracked.py"
if grep -qF "$BANNER" <<<"$ERR" && grep -qF 'org/new' <<<"$ERR" && ! grep -qF 'org/old' <<<"$ERR"; then ok "an added load is flagged, the committed one is not listed"; else fail "an added load is flagged, the committed one is not listed"; fi

# --- other files are ignored ------------------------------------------------------------------------------------------
case_quiet "a non-Python file is ignored"                  scripts/notes.md      $'m = AutoModel.from_pretrained("org/name")'

# --- every decision reached the log ----------------------------------------------------------------------------------
log_has    "DENY-lmlookup is logged for a warning"          DENY-lmlookup p1_load.py
log_has    "ALLOW-lmlookup is logged for a clean file"      ALLOW-lmlookup n_tensor.py
if grep -q '^[0-9T:-]* *[A-Za-z-]* *notes.md' "$LOG"; then fail "a non-Python file left a log line"; else ok "a non-Python file leaves no log line"; fi

echo
echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
