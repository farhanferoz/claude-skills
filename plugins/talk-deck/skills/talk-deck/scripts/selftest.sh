#!/usr/bin/env bash
# Self-test for check_deck.py: a clean deck must pass, each planted violation must
# fail naming its slide and rule, and every check must be able to fail: a copy of
# the checker with that one check disabled (a mutant) must miss its fixture.
# Run: bash scripts/selftest.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_deck.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

words() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "word " }'; }
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# run <script> <args...>: sets OUT and RC
run() { local script="$1"; shift; OUT="$(python3 "$script" "$@" 2>&1)"; RC=$?; }

must_pass() {  # description, script, args...
  local what="$1"; shift
  run "$@"
  if [ "$RC" -eq 0 ]; then ok "$what"; else bad "$what (exit $RC)"; echo "$OUT"; fi
}
must_fail() {  # description, expected text in output, script, args...
  local what="$1" want="$2"; shift 2
  run "$@"
  if [ "$RC" -eq 1 ] && grep -qF -- "$want" <<<"$OUT"; then ok "$what"
  else bad "$what (exit $RC, wanted exit 1 and '$want')"; echo "$OUT"; fi
}
must_error() {  # description, expected text on stderr, script, args...
  local what="$1" want="$2"; shift 2
  run "$@"
  if [ "$RC" -eq 2 ] && grep -qF -- "$want" <<<"$OUT"; then ok "$what"
  else bad "$what (exit $RC, wanted exit 2 and '$want')"; echo "$OUT"; fi
}

# --- fixtures ----------------------------------------------------------------
cat > "$TMP/facts.md" <<'F'
| value | date | source |
|---|---|---|
| 93% | 2026-11-01 | the cost audit |
| 3.3 GB | 2026-10-23 | the disk report |
| 12 | 2026-11 | the job log |
F
cat > "$TMP/nodate.md" <<'F'
| value | date | source |
|---|---|---|
| 93% | | the cost audit |
F
cat > "$TMP/nosource.md" <<'F'
| value | date | source |
|---|---|---|
| 93% | 2026-11-01 | |
F
cat > "$TMP/stale.md" <<'F'
| value | date | source |
|---|---|---|
| 93% | 2026-03-17 | the cost audit |
F

# clean HTML: summary words stay outside the panel, a verbatim log is outside the
# caps and the number check, years and ISO dates are not claims, a nested group.
{
  echo '<html><body>'
  echo '<section id="s1"><h1>Cost fell</h1><p>Cost fell 93% in 2026.</p></section>'
  echo "<section id=\"s2\"><h1>Disk</h1><p>3.3 GB freed on 2026-10-23, 12 jobs.</p>"
  echo "<details><summary>How it works here</summary><p>$(words 44)</p></details>"
  echo "<pre data-verbatim>$(words 200) 99999</pre></section>"
  echo '<section><section id="v1"><p>Vertical child.</p></section></section>'
  echo '</body></html>'
} > "$TMP/clean.html"
must_pass "clean HTML deck passes" "$CHECK" "$TMP/clean.html" --facts "$TMP/facts.md"

{ echo '<section id="a"><p>Short.</p></section>'
  echo "<section id=\"long\"><h1>Long one</h1><p>$(words 81)</p></section>"; } > "$TMP/overcap.html"
must_fail "over-cap slide fails, naming slide and rule" "slide 2 (long): [slide-words] 83 closed-slide words, limit 80" \
  "$CHECK" "$TMP/overcap.html"

echo "<section id=\"p\"><p>Short.</p><details><summary>More</summary><p>$(words 46)</p></details></section>" > "$TMP/overpanel.html"
must_fail "over-cap panel fails" "[panel-words] panel 1: 46 words, limit 45" "$CHECK" "$TMP/overpanel.html"

echo '<section id="n"><p>Cost fell 94%.</p></section>' > "$TMP/unsourced.html"
must_fail "number absent from the facts file fails" "[number-not-in-facts] number '94%'" \
  "$CHECK" "$TMP/unsourced.html" --facts "$TMP/facts.md"
must_fail "number with no facts file at all fails" "[number-not-in-facts]" "$CHECK" "$TMP/unsourced.html"
echo '<section id="n"><p>Cost fell 93%.</p></section>' > "$TMP/dated.html"
must_fail "facts row without a date fails" "[number-no-date]" "$CHECK" "$TMP/dated.html" --facts "$TMP/nodate.md"
must_fail "facts row without a source fails" "[number-no-source]" "$CHECK" "$TMP/dated.html" --facts "$TMP/nosource.md"
must_fail "facts row older than the window fails" "[number-stale]" \
  "$CHECK" "$TMP/dated.html" --facts "$TMP/stale.md" --window-start 2026-09-23
must_pass "the same old row passes with no window" "$CHECK" "$TMP/dated.html" --facts "$TMP/stale.md"
echo '<section id="m"><p>12 jobs ran.</p></section>' > "$TMP/month.html"
must_pass "a month-only fact counts as its last day inside the window" "$CHECK" "$TMP/month.html" --facts "$TMP/facts.md" --window-start 2026-11-05
must_fail "a month-only fact before the window fails" "[number-stale]" "$CHECK" "$TMP/month.html" --facts "$TMP/facts.md" --window-start 2026-12-01

# a per-slide cap, a configurable selector, and a settings file beside the deck
echo "<section id=\"big\"><p>$(words 120)</p></section>" > "$TMP/bigcap.html"
must_fail "120 words fails the default cap" "[slide-words]" "$CHECK" "$TMP/bigcap.html"
echo "<section id=\"big\" data-max-words=\"130\"><p>$(words 120)</p></section>" > "$TMP/bigcap.html"
must_pass "data-max-words raises one slide's cap" "$CHECK" "$TMP/bigcap.html"
echo "<div class=\"slide\"><p>$(words 90)</p></div><section><p>$(words 5)</p></section>" > "$TMP/div.html"
must_fail "--slide-selector picks the slides" "slide 1: [slide-words] 90" "$CHECK" "$TMP/div.html" --slide-selector 'div.slide'
mkdir "$TMP/cfg"; cp "$TMP/overcap.html" "$TMP/cfg/deck.html"
echo '{"max_slide_words": 100}' > "$TMP/cfg/deck-check.json"
must_pass "deck-check.json beside the deck sets the cap" "$CHECK" "$TMP/cfg/deck.html"
must_fail "a flag beats the settings file" "limit 50" "$CHECK" "$TMP/cfg/deck.html" --max-slide-words 50

# Markdown
cat > "$TMP/clean.md" <<M
# Cost fell

Cost fell 93% in 2026.

1. First point

---

## Disk

3.3 GB freed, 12 jobs.

<details><summary>More</summary>$(words 44)</details>
M
must_pass "clean Markdown deck passes" "$CHECK" "$TMP/clean.md" --facts "$TMP/facts.md"
printf -- '---\ntitle: x\n---\n# One\n\nShort.\n' > "$TMP/front.md"
must_pass "YAML front matter is not a slide" "$CHECK" "$TMP/front.md"
printf '# One\n\n%s\n\n---\n\n# Two\n\n%s\n' "$(words 50)" "$(words 50)" > "$TMP/split.md"
must_pass "two 50-word Markdown slides pass (--- splits them)" "$CHECK" "$TMP/split.md"
printf '# One\n\n%s\n' "$(words 85)" > "$TMP/overcap.md"
must_fail "over-cap Markdown slide fails" "slide 1 (One): [slide-words]" "$CHECK" "$TMP/overcap.md"

# the checker refuses to guess
must_error "missing deck exits 2 with a remedy" "Pass the path of an existing deck" "$CHECK" "$TMP/none.html"
touch "$TMP/x.pptx"
must_error "PowerPoint input is refused with a remedy" "Export the deck to HTML or Markdown" "$CHECK" "$TMP/x.pptx"
must_error "unsupported selector exits 2" "unsupported selector" "$CHECK" "$TMP/clean.html" --slide-selector 'main > section'
echo '{"max_slides": 3}' > "$TMP/cfg/deck-check.json"
must_error "unknown settings key exits 2" "unknown keys" "$CHECK" "$TMP/cfg/deck.html"
rm "$TMP/cfg/deck-check.json"
echo "<section><p>$(words 3)</p></section>" > "$TMP/zero.html"
must_error "facts file with no table exits 2" "value, date and source columns" "$CHECK" "$TMP/zero.html" --facts "$TMP/zero.html"
echo '<p>no slides here</p>' > "$TMP/noslides.html"
must_fail "a deck with no slides fails" "[no-slides]" "$CHECK" "$TMP/noslides.html"

# --- mutants: disable one check at a time; its fixture must now be missed -----
mutant() {  # name, python-source before, after -> writes $TMP/mut.py, returns 1 if no change
  python3 - "$CHECK" "$TMP/mut.py" "$2" "$3" <<'PY'
import sys
src, dst, before, after = sys.argv[1:5]
text = open(src).read()
if before not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(before, after, 1))
PY
}
missed() {  # name, before, after, deck, expected-exit-with-mutant, args...
  local name="$1" before="$2" after="$3" deck="$4" want="$5"; shift 5
  if ! mutant "$name" "$before" "$after"; then bad "mutant '$name': text to mutate not found in check_deck.py"; return; fi
  run "$TMP/mut.py" "$deck" "$@"
  if [ "$RC" -eq "$want" ]; then ok "mutant '$name' is caught by its fixture"
  else bad "mutant '$name' survived (exit $RC, wanted $want): that check cannot fail"; fi
}
missed "closed-slide word cap off" 'if words > cap:' 'if False and words > cap:' "$TMP/overcap.html" 0
missed "panel word cap off" 'if words > settings.max_panel_words:' 'if False and words > settings.max_panel_words:' "$TMP/overpanel.html" 0
missed "number not in facts passes" 'else (Rule.NUMBER_NOT_IN_FACTS, "it has no row in the facts file")' 'else None' "$TMP/unsourced.html" 0 --facts "$TMP/facts.md"
missed "undated fact passes" 'if not f.date:' 'if False:' "$TMP/dated.html" 0 --facts "$TMP/nodate.md"
missed "unsourced fact passes" 'elif not f.source:' 'elif False:' "$TMP/dated.html" 0 --facts "$TMP/nosource.md"
missed "stale fact passes" 'elif window_start and _day(f.date) < window_start:' 'elif False:' "$TMP/dated.html" 0 --facts "$TMP/stale.md" --window-start 2026-09-23
missed "summary counted in the panel" 'DISCLOSURE_LABEL_TAG = "summary"' 'DISCLOSURE_LABEL_TAG = "x-none"' "$TMP/clean.html" 1 --facts "$TMP/facts.md"
missed "verbatim text counted" 'ignore_selector: str = "script,style,template,[data-verbatim]"' 'ignore_selector: str = "script,style,template"' "$TMP/clean.html" 1 --facts "$TMP/facts.md"
missed "dates counted as numbers" '(?:19|20)\d{2}(?:-\d{2}){0,2}' '(?:19|20)\d{9}' "$TMP/clean.html" 1 --facts "$TMP/facts.md"
missed "default selector changed" 'slide_selector: str = "section"' 'slide_selector: str = "article"' "$TMP/clean.html" 1 --facts "$TMP/facts.md"
missed "Markdown separator ignored" 'MARKDOWN_RULE = re.compile(r"^---\s*$")' 'MARKDOWN_RULE = re.compile(r"^===\s*$")' "$TMP/split.md" 1
missed "month-only date read as its first day" 'date + "-31"' 'date + "-00"' "$TMP/month.html" 1 --facts "$TMP/facts.md" --window-start 2026-11-05
echo '{"max_slide_words": 100}' > "$TMP/cfg/deck-check.json"
missed "flag no longer beats settings file" 'values.update({k: v for k, v in overrides.items() if v is not None})' 'pass' "$TMP/cfg/deck.html" 0 --max-slide-words 50
missed "settings file ignored" 'if path.exists():' 'if False:' "$TMP/cfg/deck.html" 1

if [ "$fail" -eq 0 ]; then echo "SELFTEST PASS"; else echo "SELFTEST FAIL"; fi
exit "$fail"
