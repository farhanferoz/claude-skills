#!/usr/bin/env bash
# PostToolUse (Write|Edit) — deterministic code-hygiene feedback loop.
#
# Runs cheap mechanical checkers on the file just written/edited and, on
# findings, exits 2 so stderr is fed back to the model as guidance — the
# write has already landed; this makes the model fix the issue in the SAME
# turn instead of at review time (the load-bearing pattern from the 2026-07-11
# hygiene research: linter-backed hooks work, prose-only instructions don't).
#
# Checks (only what's installed; fail-open on everything):
#   *.py + ruff  -> PLR2004 magic-value-comparison (unnamed constants/strings
#                   in comparisons -> named constant / enum / Literal).
#   *.py         -> ~/.claude/scripts/dupcheck.py edit: a block of 8+ statements
#                   the edit copied from elsewhere in the repository (stdlib only;
#                   quiet outside git and on copies already committed; a test file is
#                   compared with the tests too).
#   *.py         -> in the lines the edit adds: GPU free memory read from the driver,
#                   model serving or downloading outside localmodels, and a model load
#                   that skips localmodels' settings lookup or writes a precision by hand.
#
# Never blocks the edit itself; never fails the turn (exit 0 unless findings).

payload="$(cat 2>/dev/null || true)"

file_path="$(python3 - "$payload" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.loads(sys.argv[1]).get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
PY
)"

[ -n "$file_path" ] && [ -f "$file_path" ] || exit 0

# Log every decision, ALLOWs included (D14). Reached only for real files, and the
# .py filter below keeps the volume down. Without this, "did the hygiene check
# run on that edit?" is unanswerable: a hook exiting 0 sends stderr to the debug
# log only, so a silently-missing `ruff` looks exactly like a clean file.
_log() {
    d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/code_hygiene_check.log"
    printf '%s %-14s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "${2:-}" >> "$d" 2>/dev/null || true
}

case "$file_path" in
    *.py)
        found=0
        if ! command -v ruff >/dev/null 2>&1; then
            _log "SKIP-noruff" "${file_path##*/}"
        fi
        if command -v ruff >/dev/null 2>&1; then
            findings="$(ruff check --select PLR2004 --quiet "$file_path" 2>/dev/null || true)"
            if [ -n "$findings" ]; then
                {
                    echo "Code-hygiene check (${file_path##*/}): magic values in comparisons —"
                    echo "$findings"
                    echo "Name the constant, or if the value belongs to a closed set of"
                    echo "variants, define an Enum/StrEnum/Literal and compare against that."
                    echo "Fix now unless the surrounding code deliberately uses this style."
                } >&2
                _log "DENY-PLR2004" "${file_path##*/}"
                found=1
            else
                _log "ALLOW-clean" "${file_path##*/}"
            fi
        fi
        # The helper ships beside this hook (../scripts/); readlink -f follows a symlinked install to it.
        dupcheck="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts/dupcheck.py"
        if [ -f "$dupcheck" ]; then
            # 0.7 s per edit in a 400-file repo, 1.2 s at 740 files (2026-10-16); the cap only stops a hang.
            # A test file is compared with the tests as well (2026-10-18: one project held 62 and another 91 copied
            # test bodies of 10-18 statements differing only in values; 1.7 s per test edit in the second project's suite).
            tests_flag=""
            case "$file_path" in */tests/*|*/test/*|*/test_*.py|*_test.py|*/conftest.py) tests_flag="--include-tests" ;; esac
            copies="$(timeout -k 2 15 python3 "$dupcheck" edit "$file_path" $tests_flag 2>/dev/null || true)"
            if [ -n "$copies" ]; then
                {
                    echo "Code-hygiene check (${file_path##*/}): copied code —"
                    echo "$copies"
                    echo "This edit added a block that already exists elsewhere in the repository."
                    echo "Reuse or extend the existing code (import it, or move it to one shared"
                    echo "place; in tests, parametrize one test or share a fixture) instead of keeping"
                    echo "a second copy. Fix now unless the copy is deliberate, and then say why."
                } >&2
                _log "DENY-dupcheck" "${file_path##*/}"
                found=1
            else
                _log "ALLOW-dupcheck" "${file_path##*/}"
            fi
        fi
        # The two checks below read only the lines this file adds over HEAD (the whole file outside git).
        dir="$(dirname "$file_path")"
        if git -C "$dir" ls-files --error-unmatch "$file_path" >/dev/null 2>&1; then
            added="$(git -C "$dir" diff -U0 HEAD -- "$file_path" 2>/dev/null | grep '^+[^+]' || true)"
        else
            added="$(cat "$file_path" 2>/dev/null || true)"
        fi
        # GPU free memory read from the driver: on a GPU that shares the host's RAM (the GB10) it leaves out the
        # page cache (2026-10-17: 55.9 GB by the driver against 108.1 GB available, a fit took a 3-4x slower path
        # for an hour). localmodels' own probe is the one place allowed to read it.
        case "$file_path" in
            */localmodels/hardware.py) ;;
            *)
                driver_free="$(printf '%s\n' "$added" | grep -E 'mem_get_info\(|cudaMemGetInfo\(|nvmlDeviceGetMemoryInfo\(|memory\.free' || true)"
                if [ -n "$driver_free" ]; then
                    {
                        echo "Code-hygiene check (${file_path##*/}): GPU free memory read from the driver —"
                        echo "$driver_free"
                        echo "On a GPU that shares the host's RAM (this machine's GB10) the driver's free count leaves"
                        echo "out the page cache and can report half of what an allocation can get. Decide what fits"
                        echo "with localmodels.hardware.available_memory(device) (github.com/farhanferoz/localmodels),"
                        echo "and make a refused fast path stop with an error, never fall back silently. Fix now unless"
                        echo "the driver's figure is deliberate (a fallback when available_memory returns None), and"
                        echo "then say why."
                    } >&2
                    _log "DENY-gpufree" "${file_path##*/}"
                    found=1
                else
                    _log "ALLOW-gpufree" "${file_path##*/}"
                fi
                ;;
        esac
        # Model serving, downloading and model-process management outside localmodels (localmodels programme
        # 5.2-5.3): a direct Hub download, a llama-server argument list or binary path, vLLM in process. localmodels
        # itself, tests, training and research code are exempt. Scanned 2026-10-18 as if every line were new: no
        # hit in three of the projects scanned; 8 in a fourth project's scripts, all real.
        q="[\"']"
        bypass_re="hf_hub_download\(|snapshot_download\(|\[[[:space:]]*${q}llama-server${q}|${q}[^\"' ]*/llama-server${q}|^\+?[[:space:]]*(from vllm import|import vllm)|vllm serve|${q}vllm${q}[[:space:]]*,[[:space:]]*${q}serve${q}"
        case "$file_path" in
            */src/localmodels/*|*/tests/*|*/test_*.py|*/training/*|*/research/*|*/notebooks/*|*/spikes/*)
                _log "ALLOW-lmexempt" "${file_path##*/}"
                ;;
            *)
                bypass="$(printf '%s\n' "$added" | grep -E "$bypass_re" || true)"
                if [ -n "$bypass" ]; then
                    {
                        echo "Code-hygiene check (${file_path##*/}): model serving or downloading outside localmodels —"
                        echo "$bypass"
                        echo "Serving, downloading and model-process management go through localmodels"
                        echo "(github.com/farhanferoz/localmodels; extend it, do not build beside it): one pinned,"
                        echo "hash-checked file from the shared cache with localmodels.pull.resolve_model_file;"
                        echo "llama-server started by LocalServerManager, laid out by role (ServingRole); a PyTorch"
                        echo "model in its own process with localmodels.serving. Classify the work first:"
                        echo "\`localmodels rules show K1\` .. K10. Exempt: training, exploratory research, and a model's"
                        echo "own code inside a localmodels server. Fix now unless exempt, and then say why."
                    } >&2
                    _log "DENY-lmbypass" "${file_path##*/}"
                    found=1
                else
                    _log "ALLOW-lmbypass" "${file_path##*/}"
                fi
                ;;
        esac
        # A model load that does not ask localmodels.settings.lookup for its settings, or writes a precision or a
        # llama.cpp flag by hand (localmodels programme P6, decision D4; the rule is the CLAUDE.md bullet "Every model
        # load gets its settings from localmodels"). Warn-only like the checks above, and every decision is logged.
        # The patterns are the ones that survived the 2026-10-22 scan of four of the owner's projects,
        # classified hit by hit (localmodels docs/research/measured-settings-p6-scan-2026-10-22.md);
        # a bare `torch.float32`, a bare `dtype=torch.*` and a matmul-precision switch were dropped there: nearly all
        # their hits are tensors and training numerics. The pattern block between the markers is read by the scan too.
        # lm-patterns-begin
        lm_load='^\+?[^#`]*\b(Auto[A-Za-z0-9]*|[A-Za-z]*(Model|LM|Generation|Classification))\.from_pretrained\(([^.)]|$)'
        lm_load_not='Tokenizer|Config|Processor|FeatureExtractor'
        lm_embed='^\+?[^#`]*\b(SentenceTransformer|CrossEncoder)\([^.)]'
        lm_llamacpp='^\+?[^#`]*(llama_cpp\.Llama\(|from llama_cpp import .*Llama)'
        lm_dtype_kw='^\+?[^#`]*\btorch_dtype *='
        lm_dtype_str="^\+?[^#\`]*\bdtype *= *${q}(fp32|bf16|fp16|float32|bfloat16|float16)${q}"
        lm_dtype_str_not='np\.|numpy|pandas|pd\.|astype'
        lm_record="^\+?[^#\`]*precision${q} *: *${q}(fp32|bf16|fp16|float32|bfloat16)"
        lm_flags="^\+?[^#\`]*(n_ubatch *=|${q}-ub${q}|--ubatch-size|${q}--spec-type${q})"
        # lm-patterns-end
        lm_explicit='# localmodels: explicit'
        # Exempt: the bypass block's paths, plus training and research that sit outside those directories (a
        # planning/ folder of load-time investigations, spike_*.py, training scripts named train_*/lora_*/finetune_*)
        # plus any globs the user lists in CLAUDE_PLUGIN_OPTION_LM_LOOKUP_EXEMPT_GLOBS (colon-separated; default none),
        # for example a whole research repository whose code loads no language model.
        lm_extra_exempt=""
        IFS=':' read -r -a lm_exempt_globs <<< "${CLAUDE_PLUGIN_OPTION_LM_LOOKUP_EXEMPT_GLOBS:-}"
        for g in ${lm_exempt_globs[@]+"${lm_exempt_globs[@]}"}; do
            # shellcheck disable=SC2053  # $g is a glob on purpose
            [[ -n "$g" && "$file_path" == $g ]] && lm_extra_exempt="$file_path"
        done
        case "$file_path" in
            "$lm_extra_exempt"|*/src/localmodels/*|*/tests/*|*/test_*.py|*/training/*|*/research/*|*/notebooks/*|\
            */spikes/*|*/planning/*|*/spike_*.py|*/train_*.py|*/*_train.py|*/training.py|*/finetune_*.py|*/lora_*.py)
                _log "ALLOW-lmlookup-exempt" "${file_path##*/}"
                ;;
            *)
                # A file that already imports localmodels.settings has adopted the lookup: the hook cannot tell which
                # load a lookup serves, so it leaves the whole file alone (a second, unadopted load in it goes unseen).
                if grep -qE 'localmodels\.settings|from localmodels import[^#]*\b(settings|lookup)\b' "$file_path" 2>/dev/null; then
                    _log "ALLOW-lmlookup-adopted" "${file_path##*/}"
                # A file defining a localmodels ModelServer is a model's own code inside a localmodels server (exempt):
                # its precision arrives in the server's load message, which the tune record decides.
                elif grep -qE '^class [A-Za-z0-9_]+\(([^)]*[ ,.])?ModelServer\)' "$file_path" 2>/dev/null; then
                    _log "ALLOW-lmlookup-served" "${file_path##*/}"
                else
                    lm_all="$(
                        {
                            printf '%s\n' "$added" | grep -E "$lm_load" | grep -vE "$lm_load_not"
                            printf '%s\n' "$added" | grep -E "$lm_embed"
                            printf '%s\n' "$added" | grep -E "$lm_llamacpp"
                            printf '%s\n' "$added" | grep -E "$lm_dtype_kw"
                            printf '%s\n' "$added" | grep -E "$lm_dtype_str" | grep -vE "$lm_dtype_str_not"
                            printf '%s\n' "$added" | grep -E "$lm_record"
                            printf '%s\n' "$added" | grep -E "$lm_flags"
                        } | awk '!seen[$0]++' || true
                    )"
                    lm_flagged="$(printf '%s\n' "$lm_all" | grep -vF "$lm_explicit" | grep -v '^$' || true)"
                    lm_declared="$(printf '%s\n' "$lm_all" | grep -F "$lm_explicit" || true)"
                    [ -n "$lm_declared" ] && _log "ALLOW-lmlookup-explicit" "${file_path##*/}"
                    if [ -n "$lm_flagged" ]; then
                        {
                            echo "Code-hygiene check (${file_path##*/}): model load without localmodels' settings lookup —"
                            echo "$lm_flagged"
                            echo "Every model load gets its settings from localmodels (github.com/farhanferoz/localmodels):"
                            echo "ask localmodels.settings.lookup(model, kind, engine=...) before the load and apply the"
                            echo "answer's precision, batch or token budget, engine and llama.cpp settings; keep its status"
                            echo "in the result's stamp (answer.server_stamp(...)), so an untuned or stale result shows. A"
                            echo "setting you must fix yourself goes in lookup(..., explicit={...}) with the reason, and the"
                            echo "line that fixes it ends in the comment  # localmodels: explicit . Classify the work first:"
                            echo "\`localmodels rules show K1\` .. K10. Exempt: training, exploratory research, and a model's"
                            echo "own code inside a localmodels server. Fix now unless exempt, and then say why."
                        } >&2
                        _log "DENY-lmlookup" "${file_path##*/}"
                        found=1
                    else
                        _log "ALLOW-lmlookup" "${file_path##*/}"
                    fi
                fi
                ;;
        esac
        [ "$found" = 1 ] && exit 2
        ;;
esac
exit 0
