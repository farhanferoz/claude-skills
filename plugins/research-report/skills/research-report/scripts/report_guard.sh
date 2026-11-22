#!/usr/bin/env bash
# Shared hard guard for research reports.
# Governed by notes/research/RESEARCH_REPORT_CONTRACT.md.
# Usage:  bash _build/report_guard.sh <markdown-file>
# Exits 1 and lists every violation if the doc breaks any contract rule that
# has a textual signature. Semantic rules (terms defined, math derived) are not
# greppable and are owned by the cold-reader pass.
set -euo pipefail

DOC="${1:?usage: report_guard.sh <markdown-file>}"
fail=0
report() { echo "GUARD: $1" >&2; fail=1; }

# --- 1. No "section 0": numbering starts at 1 (DOC_STANDARD). -----------------
if grep -nE "^#+ 0[. ]" "$DOC" >&2; then
  report "section-0 heading — start numbering at 1."
fi

# --- 2. No literal radical sign anywhere. -------------------------------------
if grep -n "√" "$DOC" >&2; then
  report "literal √ — use \\sqrt{} in math, sqrt() in code."
fi

# --- 3. Math never in code spans; unicode math never inside \$...\$. ------------
if ! python3 - "$DOC" <<'PY'
import re, sys
MATH_CHARS = re.compile(r"[λσκαβεπτμξδγωΣΔρηΦ≈≤≥∼→·‖√∞±∇∂×−½]")
FORMULA_HINTS = re.compile(r"sqrt\(|\bmean\(|\blog [a-z]|\bE\[")
bad, in_fence = [], False
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence; continue
    if in_fence: continue
    for seg in line.split("`")[1::2]:
        if MATH_CHARS.search(seg) or FORMULA_HINTS.search(seg):
            bad.append((n, "math in code span", seg.strip()))
    for seg in line.split("$")[1::2]:
        if MATH_CHARS.search(seg):
            bad.append((n, "unicode math char inside $...$", seg.strip()))
for n, why, seg in bad:
    print(f"GUARD: line {n}: {why}: {seg!r}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# --- 4. No machine-local paths or working-branch names. -----------------------
if grep -nE "/home/|\.venv|add-gaussian|add-energy|nll-es-integration" "$DOC" >&2; then
  report "machine-local path or working-branch name."
fi

# --- 5. NO CODE REFERENCES (contract rule 1; strict, unlike a code-explainer).
#     File extensions, source-tree path prefixes, and code-like backtick spans
#     (snake_case, CamelCase, call syntax, dotted attr, slashes).
if grep -noE '\b[A-Za-z0-9_./-]+\.(py|ya?ml|sh|ipynb|toml|cfg|json)\b' "$DOC" >&2; then
  report "code reference: file with a source extension — write what it does, not where it lives."
fi
if grep -noE '\b(src|tests|configs?|scripts|local_hydra|notes|outputs)/[A-Za-z0-9_./-]+' "$DOC" >&2; then
  report "code reference: source-tree path — describe the thing, not its path."
fi
# Backtick spans that look like code (not prose, not a single italic symbol).
if ! python3 - "$DOC" <<'PY'
import re, sys
CODEY = re.compile(r"[a-z0-9]_[a-z0-9]|[a-z][A-Z]|\(\)|\.[a-z]|/")  # snake/Camel/call/attr/path
bad, in_fence = [], False
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence; continue
    if in_fence: continue
    for seg in line.split("`")[1::2]:
        if CODEY.search(seg):
            bad.append((n, seg.strip()))
for n, seg in bad:
    print(f"GUARD: line {n}: code-like backtick span: {seg!r}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# --- 6. Banned-word denylist (contract rule 2; grows as new jargon is flagged).
#     Only UNAMBIGUOUS coinages/misuses belong here. A real word whose fitness is
#     context-dependent (e.g. "pricing"/"mispricing" or "oracle" — correct domain
#     terms in a finance report, jargon-misuse in an ML one) is the cold reader's
#     call, not a hard ban, so this guard stays domain-portable. Add a word here
#     the first time it is flagged, so the same fancy term never ships twice.
# Stems (no -w, so inflections are caught: amortis->amortised, slave->slaved).
DENY='amortis|amortiz|slave|slaver|surrogate|fee-dead|fee-kill|prob-reg|sleeve|arena|rung'
if grep -niE "$DENY" "$DOC" >&2; then
  report "banned fancy/coined word (see denylist) — use a plain word or define it plainly."
fi

# --- 6b. Bare snake_case identifiers in prose or table cells (contract rule 1).
#     Rule 5 only looks inside backtick spans, so a configuration key typed as
#     plain text went straight through: "none stated (scale_factor 1 in the
#     configuration table)" sat in an appendix table cell of the 2026-10-20
#     autoencoder report, three times, with the guard clean. Math, citation
#     keys, link/image targets, URLs and HTML comments are stripped first.
if ! python3 - "$DOC" <<'PY'
import re, sys
STRIP = [r"\$\$.*?\$\$", r"\$[^$\n]*\$", r"`[^`]*`", r"<!--.*?-->", r"\[@[^\]]*\]",
         r"@[A-Za-z0-9_:.-]+", r"\]\([^)]*\)", r"https?://\S+", r"\{[^}\n]*\}"]
SNAKE = re.compile(r"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b")
text = open(sys.argv[1], encoding="utf-8").read()
blank = lambda m: "\n" * m.group(0).count("\n")   # keep line numbers
for multi in (r"```.*?```", r"\$\$.*?\$\$", r"\$[^$]*?\$", r"<!--.*?-->"):
    text = re.sub(multi, blank, text, flags=re.S)
bad = []
for n, line in enumerate(text.split("\n"), 1):
    for pat in STRIP:
        line = re.sub(pat, " ", line, flags=re.S)
    bad += [(n, m.group(0)) for m in SNAKE.finditer(line)]
for n, tok in bad:
    print(f"GUARD: line {n}: bare identifier {tok!r} — a configuration key or code "
          f"name in the text; say what it does instead.", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# --- 7. No thematic-break rules between sections (contract: book-chapter form).
#     A LEADING YAML METADATA BLOCK IS EXEMPT. Its delimiter is also '---', and
#     it is the only way to give pandoc a real title/author/date -- without it
#     pandoc has no \maketitle, so with --toc the contents page renders ABOVE the
#     title. Flagging front matter therefore forced every report into that
#     layout. Thematic breaks anywhere else still hard-fail.
if ! python3 - "$DOC" <<'PYEOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
exempt = set()
if lines and lines[0].strip() == "---":
    for n in range(1, len(lines)):
        if lines[n].strip() in ("---", "..."):
            exempt = {0, n}
            break
bad = [(n + 1, l) for n, l in enumerate(lines)
       if re.match(r"^(---|\*\*\*|___)\s*$", l) and n not in exempt]
for n, l in bad:
    print(f"GUARD: line {n}: thematic-break rule ({l.strip()}) — book chapters do "
          f"not separate sections with rules.", file=sys.stderr)
sys.exit(1 if bad else 0)
PYEOF
then fail=1; fi

# --- 8. Figure coverage (contract rule 7): every figure generated for this -----
#     report is embedded. The doc declares its figure namespace(s) in a manifest
#     comment near the top:  <!-- report-figures: kalshi-flb pm-cost -->  . For
#     each prefix, every matching PNG in the sibling figures/ dir must be
#     referenced in the doc; an existing-but-unembedded figure hard-fails. This
#     is the completeness gate the build alone cannot give (the build only
#     catches the reverse — a referenced figure that is missing). Namespacing by
#     prefix keeps a shared figures/ dir (several reports) from cross-firing.
#     No manifest → not enforced (prints a notice), so non-figure docs still pass.
FIGDIR="$(dirname "$DOC")/figures"
MANIFEST="$(grep -oiE '<!--[[:space:]]*report-figures:[^>]*-->' "$DOC" | head -1 \
            | sed -E 's/.*report-figures:[[:space:]]*//I; s/[[:space:]]*-->.*//' || true)"
if [ -z "$MANIFEST" ]; then
  echo "GUARD: note — no <!-- report-figures: ... --> manifest; figure-coverage not enforced." >&2
elif [ -d "$FIGDIR" ]; then
  for prefix in $MANIFEST; do
    for f in "$FIGDIR/$prefix"*.png "$FIGDIR/$prefix"*.pdf; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      if ! grep -qF "$base" "$DOC"; then
        report "figure $base exists (prefix '$prefix') but is not embedded — surface it, or move it out of figures/."
      fi
    done
  done
fi

# --- 9-12. STRUCTURE (contract rule 9; see references/structure.md). ----------
#     The clarity rules above check sentences. These check the document: heading
#     register, caption length, section-size skew, and evidence per section.
#     They exist because a report can pass every per-sentence gate and still be
#     built wrong — the signature of a document grown by accretion rather than
#     authored, where every correction is right and the shape is not.
if ! python3 - "$DOC" <<'PY'
import re, sys, statistics

doc = sys.argv[1]
lines = open(doc, encoding="utf-8").read().split("\n")
bad, notes = [], []

# Strip fenced code so headings/captions inside samples are not judged.
body, in_fence = [], False
for n, line in enumerate(lines, 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence
        body.append((n, ""))
        continue
    body.append((n, "" if in_fence else line))

# --- 9. Heading register: name the subject, do not comment on it. -------------
# Unambiguous register commentary. A heading is a label, not an editorial.
REGISTER = re.compile(
    r"\b(in plain terms|plain-english|honest(ly)?|the headline|really|actually|"
    r"truly|what it all means|read(ing)? this|a note on|some thoughts)\b", re.I)
headings = [(n, l) for n, l in body if re.match(r"^#{1,6}\s", l)]
for n, l in headings:
    text = re.sub(r"^#+\s*", "", l).strip()
    m = REGISTER.search(text)
    if m:
        bad.append((n, f"heading register: {m.group(0)!r} comments on the section "
                       f"instead of naming it: {text!r}"))
    if text.endswith("?"):
        bad.append((n, f"heading is a rhetorical question — name the subject: {text!r}"))

# Colon-gloss used as a tic: fine once or twice, not as the house pattern.
tops = [re.sub(r"^#+\s*", "", l).strip() for n, l in headings if re.match(r"^##\s", l)]
glossed = [t for t in tops if ": " in t]
if len(tops) >= 6 and len(glossed) * 3 > len(tops):
    bad.append((0, f"heading tic: {len(glossed)} of {len(tops)} top-level headings use the "
                   f"'Subject: what it means' form — vary them, or name the subject alone"))

# --- 10. Table captions name; prose explains. ---------------------------------
CAP_MAX = 30
for n, l in body:
    m = re.match(r"^\*\*(Table[^*]{0,400})\*\*", l.strip())
    if m:
        w = len(m.group(1).split())
        if w > CAP_MAX:
            bad.append((n, f"table caption is {w} words (max {CAP_MAX}) — a caption names "
                           f"what the table shows; caveats belong in the prose or a footnote"))

# --- 11. Section-size skew: an oversized section has more than one job. --------
SKEW = 3.0
sec = []  # (line, title, words, tablerows, figures)
cur = None
for n, l in body:
    if re.match(r"^##\s", l):                       # top-level section
        if cur:
            sec.append(cur)
        cur = [n, re.sub(r"^#+\s*", "", l).strip(), 0, 0, 0]
    elif cur is not None:
        s = l.strip()
        if s.startswith("|"):
            cur[3] += 1
        elif s.startswith("!["):
            cur[4] += 1
        elif not s.startswith("#"):
            cur[2] += len(s.split())
if cur:
    sec.append(cur)

sized = [s for s in sec if s[2] >= 50]              # ignore containers/References
total = sum(s[2] for s in sized) or 1
# Two conditions, both required. A section can honestly run 4x the median in a
# 20-section report; what is never right is one section that is BOTH anomalous
# among its siblings AND a large share of the reader's whole time.
SHARE = 0.15
if len(sized) >= 4:
    med = statistics.median(s[2] for s in sized)
    for n, title, w, _, _ in sized:
        if w > SKEW * med and w / total > SHARE:
            bad.append((n, f"section is {w} words — {w/med:.1f}x the {med:.0f}-word median "
                           f"and {100*w/total:.0f}% of the document — it is carrying more "
                           f"than one job, split it: {title!r}"))

# --- 12. Evidence per section, and the structure manifest (notices). ----------
# A long section with no figure is where evidence hides in prose (contract rule 7).
# Sections that legitimately carry no figure are excluded by title.
NO_FIG_OK = re.compile(r"executive summary|references|appendix|limitation|caveat|"
                       r"further work|acknowledg|glossary|scope", re.I)
for n, title, w, rows, figs in sized:
    if w >= 1200 and figs == 0 and not NO_FIG_OK.search(title):
        shown = f"{rows} table rows" if rows else "no table"
        notes.append(f"line {n}: section is {w} words with no figure ({shown}) — "
                     f"every idea worth discussing earns one: {title!r}")

text = "\n".join(l for _, l in body)

# Hard-coded float references are POSITIONAL: pandoc numbers figures by order
# of appearance, so reordering sections silently repoints every one of them at
# the wrong image, with no error anywhere. Observed doing exactly that across a
# whole document. Flag the pattern so a reviser knows to re-verify them.
nfig = len(re.findall(r"^!\[", text, re.M))
refs = sorted({int(m) for m in re.findall(r"\bFigure (\d+)\b", text)})
if nfig and refs:
    notes.append(f"{len(refs)} hard-coded 'Figure N' reference(s) against {nfig} "
                 f"embedded figures — these are positional and break silently on any "
                 f"reorder; re-verify each against the figure it now names.")
    bad_hi = [r for r in refs if r > nfig]
    if bad_hi:
        bad.append((0, f"'Figure {bad_hi[0]}' referenced but the document embeds only "
                       f"{nfig} figures"))

m = re.search(r"<!--\s*report-structure:\s*([^>]*?)\s*-->", text, re.I)
VALID = {"per-subject", "per-stage", "compositional"}
if not m:
    notes.append("no <!-- report-structure: ... --> manifest — declare the spine "
                 "(per-subject | per-stage | compositional) before drafting; "
                 "see references/structure.md rule 1.")
elif m.group(1).strip().lower() not in VALID:
    bad.append((0, f"report-structure manifest is {m.group(1)!r}; expected one of "
                   f"{sorted(VALID)}, or a named spine plus a line saying what decides "
                   f"the sections"))

for note in notes:
    print(f"GUARD: note — {note}", file=sys.stderr)
for n, why in bad:
    print(f"GUARD: {f'line {n}: ' if n else ''}{why}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# --- 13-15. BUDGET, GENERATED TABLES, RETRACTED VALUES. -----------------------
#     Rules 9-12 check the document's SHAPE relative to itself; a report every
#     one of whose sections is at 40% of its agreed budget has perfect internal
#     proportion and passes them all. Measured 2026-08-12: a draft of ~7,000
#     words against an agreed 16,400 passed clean, and every complaint that came
#     back -- toys with no technical detail, models with no mathematics, missing
#     figures -- was that one number. These three rules give the guard an
#     EXTERNAL reference: the section list the draft was written against, the
#     readout the numbers come from, and the ledger of values already retracted.
if ! python3 - "$DOC" <<'PY'
import ast, os, re, sys

doc = sys.argv[1]
docdir = os.path.dirname(os.path.abspath(doc))
text = open(doc, encoding="utf-8").read()
lines = text.split("\n")
bad, notes = [], []


def norm(s):
    """Compare headings by their subject, not their numbering or punctuation."""
    s = s.lower()
    s = re.sub(r"^\s*(appendix\s+)?[0-9ivx]+\s*[.):-]?\s*", "", s)
    s = re.sub(r"[^a-z0-9 ]", " ", s)
    return " ".join(s.split())


# Split the document at EVERY heading of level 2+, because the budget is written
# at that granularity: one row per model, per system, per results section.
sections, cur = [], None
in_fence = False
for n, line in enumerate(lines, 1):
    if line.lstrip().startswith("```"):
        in_fence = not in_fence
        continue
    if in_fence:
        continue
    if re.match(r"^#{1,6}\s", line):
        cur = {"line": n, "title": re.sub(r"^#+\s*", "", line).strip(),
               "lvl": len(re.match(r"^(#{1,6})", line).group(1)),
               "words": 0, "tables": 0, "figures": 0, "in_table": False}
        sections.append(cur)
    elif cur is not None:
        s = line.strip()
        if s.startswith("|"):
            if not cur["in_table"]:
                cur["tables"] += 1          # count TABLES, not rows
                cur["in_table"] = True
        else:
            cur["in_table"] = False
            if s.startswith("!["):
                cur["figures"] += 1
            elif not s.startswith("#") and not s.startswith("<!--"):
                cur["words"] += len(s.split())

# --- 13. The draft must match the section list it was written against. --------
sl = os.path.join(docdir, "SECTION_LIST.md")
if not os.path.exists(sl):
    notes.append("no SECTION_LIST.md beside the document — budget conformance is NOT "
                 "enforced. A new report writes one at skill step 0b; an existing report "
                 "gets one through adoption.")
else:
    sltext = open(sl, encoding="utf-8").read()
    # Owner ruling, 2026-09-05: a gate that blocks on a human makes autonomous runs
    # impossible, so it is ENFORCEABLE BY AN OPTION AND OFF BY DEFAULT. Set
    # REPORT_REQUIRE_SIGNOFF=1 to make a missing marker fatal again. What actually
    # caught the 43%-of-budget draft is the budget conformance check below, which
    # runs unconditionally either way.
    _signoff = os.environ.get("REPORT_REQUIRE_SIGNOFF", "").strip().lower()
    require_signoff = _signoff in {"1", "true", "yes", "on"}
    if not re.search(r"<!--\s*agreed-by:\s*[^>]*\S[^>]*-->", sltext, re.I):
        _m = "SECTION_LIST.md carries no <!-- agreed-by: NAME, DATE --> marker."
        if require_signoff:
            bad.append((0, _m + " REPORT_REQUIRE_SIGNOFF=1 is set, so this is fatal: the "
                             "budget was never signed off by whoever asked for the report."))
        else:
            notes.append(_m + " Sign-off is OFF by default (owner ruling 2026-09-05); "
                              "set REPORT_REQUIRE_SIGNOFF=1 to enforce it.")

    budget, in_tbl = [], False
    for line in sltext.split("\n"):
        s = line.strip()
        if re.match(r"^\|\s*part\s*\|\s*section\s*\|", s, re.I):
            in_tbl = True
            continue
        if in_tbl:
            if not s.startswith("|"):
                in_tbl = False
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) < 5 or set(cells[0]) <= set("-: "):
                continue
            if "total" in cells[1].lower() or not cells[1]:
                continue
            def num(c):
                d = re.sub(r"[^0-9]", "", c)
                return int(d) if d else 0
            budget.append((cells[1], num(cells[2]), num(cells[3]), num(cells[4])))

    if not budget:
        notes.append("SECTION_LIST.md has no parseable '| part | section | words | tables | "
                     "figures |' budget table — conformance not enforced.")
    else:
        stated = re.search(r"\|\s*\*\*total\*\*\s*\|\s*\*\*([0-9,]+)\*\*", sltext, re.I)
        if stated:
            declared = int(stated.group(1).replace(",", ""))
            actual = sum(b[1] for b in budget)
            if declared != actual:
                notes.append(f"SECTION_LIST.md's stated total is {declared:,} words but its "
                             f"rows sum to {actual:,} — fix the list's own arithmetic.")

        # Match budget rows to real sections by TITLE OVERLAP, assigning the
        # best pairs first. First-match-wins was tried and is wrong: a short
        # title like "Conclusion" is a substring of half the document's
        # headings, so rows bound to whatever came first and the true section
        # then reported as absent. A guard that cries wolf gets ignored, which
        # is the one failure mode it cannot afford.
        STOP = {"the", "a", "an", "of", "and", "or", "its", "for", "in", "on",
                "at", "to", "what", "which", "why", "how", "that", "this",
                "with", "is", "are", "it", "as", "by", "from", "each"}

        def toks(s):
            return {w for w in norm(s).split() if w not in STOP} or {"?"}

        pairs = []
        for bi, (title, bw, bt, bf) in enumerate(budget):
            for si, sec in enumerate(sections):
                a, b = toks(title), toks(sec["title"])
                score = len(a & b) / len(a | b)
                if a <= b or b <= a:                  # one title contains the other
                    score = max(score, 0.75)
                pairs.append((score, bi, si))
        pairs.sort(reverse=True)

        THRESH = 0.34
        row_of, taken = {}, set()
        best_seen = {}
        for score, bi, si in pairs:
            best_seen.setdefault(bi, (score, sections[si]["title"]))
            if score < THRESH or bi in row_of or si in taken:
                continue
            row_of[bi], _ = si, taken.add(si)

        # A budget row covers its section AND every deeper heading under it that
        # has no budget row of its own. Section lists routinely budget commentary
        # subsections "with their parent" and give them no row; counting those
        # separately made the guard cry wolf -- measured 2026-08-13 on a real
        # report, a 442-word Limitations section carrying all its prose in four
        # unbudgeted subsections was reported as 0 words against a 450-word
        # budget, and three results sections at 62-85% of budget were reported at
        # 26-31%. Absorption stops at the first heading that owns a row, because
        # that heading and its subtree are that row's job, not this one's.
        for bi, si in row_of.items():
            sec = sections[si]
            for k in range(si + 1, len(sections)):
                if sections[k]["lvl"] <= sec["lvl"] or k in taken:
                    break
                for key in ("words", "tables", "figures"):
                    sec[key] += sections[k][key]

        for bi, (title, bw, bt, bf) in enumerate(budget):
            if bi not in row_of:
                sc, cand = best_seen.get(bi, (0.0, "nothing"))
                bad.append((0, f"no section matches the budget row {title!r} "
                               f"(closest heading: {cand!r}, {100*sc:.0f}% title overlap). "
                               f"Either the section is missing -- an under-populated roster "
                               f"shows up as several missing rows -- or the section list is "
                               f"stale. Reconcile them; do not leave the budget describing a "
                               f"document that no longer exists."))
                continue
            sec = sections[row_of[bi]]
            if sec["tables"] < bt:
                bad.append((sec["line"], f"section {sec['title']!r} has {sec['tables']} "
                                         f"table(s), budget says {bt} -- a budgeted table that "
                                         f"never appeared is evidence paraphrased in prose"))
            if sec["figures"] < bf:
                bad.append((sec["line"], f"section {sec['title']!r} has {sec['figures']} "
                                         f"figure(s), budget says {bf}"))
            # Words are a WARNING, never a failure: a hard floor is satisfied by
            # padding, which is worse than brevity. The signal is the PATTERN --
            # many sections short at once is the sprint signature.
            if bw and sec["words"] < 0.7 * bw:
                notes.append(f"line {sec['line']}: section {sec['title']!r} is "
                             f"{sec['words']} words against a {bw}-word budget "
                             f"({100*sec['words']/bw:.0f}%)")
            elif bw and sec["words"] > 1.3 * bw:
                notes.append(f"line {sec['line']}: section {sec['title']!r} is "
                             f"{sec['words']} words against a {bw}-word budget "
                             f"({100*sec['words']/bw:.0f}%) -- it may be carrying "
                             f"another section's job")
        short = [n for n in notes if "against a" in n and "%)" in n]
        if len(short) >= max(3, len(budget) // 3):
            bad.append((0, f"{len(short)} of {len(budget)} sections are off their agreed "
                           f"budget. That is not a per-section miss, it is a draft written "
                           f"against a different document than the one that was agreed — "
                           f"re-author, do not pad."))

# --- 14. Results tables are generated from the readout, never typed. ----------
#     Twelve hand-retyped tables shipped in a shape the readout never produced,
#     which is where the odd headers and stranded verdict lines came from.
regions, start = [], None
for n, l in enumerate(lines):
    if re.search(r"<!--\s*BEGIN\b[^>]*table:", l, re.I):
        start = n
    elif re.search(r"<!--\s*END\b[^>]*table:", l, re.I) and start is not None:
        regions.append((start, n))
        start = None

NUMERIC = re.compile(r"^[-+±−–— 0-9.,eExX×^{}$\\\\()/%]*[0-9]"
                     r"[-+±−–— 0-9.,eExX×^{}$\\\\()/%]*$")
i = 0
while i < len(lines):
    if lines[i].strip().startswith("|"):
        j = i
        while j < len(lines) and lines[j].strip().startswith("|"):
            j += 1
        block = [b.strip() for b in lines[i:j]]
        body = [b for b in block if not set(b.strip("| ")) <= set("-:| ")]
        cells = [c.strip() for b in body[1:] for c in b.strip("|").split("|")]
        cells = [c for c in cells if c]
        if len(body) - 1 >= 3 and cells:
            numeric = [c for c in cells if NUMERIC.match(c)]
            if len(numeric) >= 0.6 * len(cells):
                inside = any(a <= i <= b for a, b in regions)
                manual = any("table: manual" in lines[k].lower()
                             for k in range(max(0, i - 3), i))
                if not inside and not manual:
                    bad.append((i + 1, "results table is hand-written. Numeric tables are "
                                       "spliced from the readout between BEGIN/END table "
                                       "markers so they cannot drift from it; a genuinely "
                                       "hand-made table is marked <!-- table: manual -->."))
        i = j
    else:
        i += 1

# --- 15. A retracted value can never ship again. ------------------------------
#     Same mechanism as the jargon denylist: once a number is superseded it
#     becomes a literal string the guard refuses, so no later revision can
#     reintroduce it from an old paragraph.
rv = os.path.join(docdir, "evidence", "retracted_values.txt")
if os.path.exists(rv):
    for ln in open(rv, encoding="utf-8"):
        entry = ln.split("#")[0].strip()
        if not entry:
            continue
        value, _, why = entry.partition("|")
        value = value.strip()
        if value and value in text:
            bad.append((0, f"retracted value {value!r} appears in the document"
                           + (f" — {why.strip()}" if why.strip() else "")))

# --- 16-18. LAYOUT. -----------------------------------------------------------
#     Added 2026-08-13 after a review round in which every finding was a
#     PRESENTATION class with many instances, and each round fixed the instances.
#     The guard caught none of them, so every cold read handed back more of the
#     same classes elsewhere. These rules ARE the classes. Same mechanism as the
#     jargon denylist and the retracted-value list: what the human gate finds
#     once becomes something the mechanical gate refuses forever.

# --- 16. A caption is not followed by a note block. ---------------------------
#     Rule 10 caps caption LENGTH, but what ships is a legal-length caption with
#     sixty words of caveat stacked underneath in a different typographic
#     register, which on the page reads as one enormous caption. Rule 10 also
#     only matched "**Table ...**", so a pandoc "Table: ..." caption was
#     invisible to it -- which is exactly how this shipped. Both forms here.
# ⚠ `body` is REBOUND by rule 14 to a list of plain strings, so by the time these
# rules run it is no longer the (line-number, text) pairs rule 9 built. Rebuild
# it locally rather than depend on a name an earlier rule mutates.
_body, _fence = [], False
for _n, _line in enumerate(lines, 1):
    if _line.lstrip().startswith("```"):
        _fence = not _fence
        _body.append((_n, ""))
        continue
    _body.append((_n, "" if _fence else _line))

#     ⚠ REFINED after over-firing: ordinary body prose following a table is
#     normal and must not be flagged. The defect is a note typeset INSIDE the
#     table's own size block -- same small font as the cells, hard against the
#     caption -- which is what reads as one huge caption. So the rule fires only
#     while a size block is open (\footnotesize/\small/\scriptsize not yet
#     closed by \normalsize). That is the typographic condition, not a proxy.
NOTE_MAX = 25
_small = False
for _i, (_n, _l) in enumerate(_body):
    _t = _l.strip()
    if re.search(r"\\(footnotesize|small|scriptsize)\b", _t):
        _small = True
    if re.search(r"\\normalsize\b", _t):
        _small = False
    if not _small:
        continue
    if not (re.match(r"^\*\*(Table|Figure)\b", _t) or re.match(r"^(Table|Figure):", _t)):
        continue
    # Skip the blank line that separates caption from note in the SOURCE --
    # they render adjacent on the page, which is where the defect lives. Then
    # measure the paragraph that lands directly under the caption.
    _w, _started = 0, False
    for _n2, _l2 in _body[_i + 1:]:
        _t2 = _l2.strip()
        if not _t2:
            if _started:
                break
            continue
        if _t2.startswith(("#", "|", "!", "<!--", "\\")):
            break
        _started = True
        _w += len(_t2.split())
    if _w > NOTE_MAX:
        bad.append((_n, f"caption is followed by a {_w}-word note (max {NOTE_MAX}) -- "
                        "a caption plus a note block reads on the page as one huge "
                        "caption; move it into the prose that argues from the object"))

# --- 17. A wide table does not starve its label column. ----------------------
#     Pandoc derives a pipe table's column widths from the RELATIVE dash counts
#     in the separator row, so "|:--|--:|--:|..." gives every column an equal
#     share and an eight-column table leaves the measurement name an eighth of
#     the measure. Every label then wraps to three, four, five lines. The markdown
#     looks perfectly tidy; only the page shows it. Flag a wide table whose long
#     labels are paired with a label column that was given no extra share.
LABEL_MAX, COLS_WIDE, MIN_SHARE = 22, 6, 0.15
_seen = set()
for _i, (_n, _l) in enumerate(_body):
    _t = _l.strip()
    if not (_t.startswith("|") and _t.count("|") >= COLS_WIDE + 1):
        continue
    if set(_t.strip("| ")) <= set("-:| "):
        continue                      # separator row, not a data row
    _label = _t.split("|")[1].strip().strip("*")
    if len(_label) <= LABEL_MAX:
        continue
    # find this table's separator row (the next all-dashes row above or below)
    _sep = None
    for _j in range(max(0, _i - 3), min(len(_body), _i + 3)):
        _c = _body[_j][1].strip()
        if _c.startswith("|") and set(_c.strip("| ")) <= set("-:| ") and "-" in _c:
            _sep = _c
            break
    if _sep is None:
        continue
    _cols = [c for c in _sep.strip("|").split("|") if c]
    _dashes = [c.count("-") for c in _cols]
    if not _dashes or sum(_dashes) == 0:
        continue
    _share = _dashes[0] / sum(_dashes)
    if _share < MIN_SHARE and id(_sep) not in _seen:
        _seen.add(id(_sep))
        bad.append((_n, f"row label {_label[:30]!r} is {len(_label)} chars but the "
                        f"label column gets only {_share:.0%} of a "
                        f"{len(_cols)}-column table's width (min {MIN_SHARE:.0%}) -- "
                        "labels will wrap to several lines; widen the label column's "
                        "share in the separator row"))

# --- 18. Figures do not carry their explanation inside the image. -------------
#     In-image prose renders in the plotting library's font at whatever size the
#     canvas implies, sits ABOVE the real caption, and cannot be restyled to
#     match the document. The caption is where an explanation belongs.
#
#     ⚠ THIS RULE HAS BEEN WRONG TWICE; both failures are encoded below.
#     (1) A first version asked for 100+ characters INSIDE the quotes, which made
#         the match skip the real closing quote and run across statements -- a
#         false positive pointing at innocent code.
#     (2) It then MISSED a live defect (two figures shipping ALL-CAPS working
#         notes) for three separate reasons: it looked only in `docdir`, while
#         the generator lived in another repo; it matched only `suptitle`/
#         `set_title` taking a DIRECT literal, while the call went through a
#         `_caption(fig, ...)` helper that passed a variable; and it matched only
#         single-line literals, while the text was a multi-line implicit
#         concatenation.
#     So this is now an AST walk, not a regex -- implicit concatenation, f-strings
#     and helper calls all parse the same way -- and the file list is extensible.
#     Generators outside the report directory are named one per line in
#     `<docdir>/.report_generators` (absolute, or relative to docdir).
_gen_paths = [os.path.join(docdir, _n)
              for _n in ("make_figures.py", "present_grid.py")]
_extra = os.path.join(docdir, ".report_generators")
if not os.path.exists(_extra):
    # ⚠ The silence this rule used to keep is the whole reason it missed a live
    # defect: a generator in another repo was simply never opened, and nothing
    # said so. Absence of the file is now STATED, not assumed to mean "no
    # outside generators".
    notes.append("no .report_generators here, so rule 18 checked only "
                 "generators inside the report directory -- if a figure is "
                 "drawn by a script living elsewhere, name it there or it goes "
                 "unchecked")
if os.path.exists(_extra):
    for _line in open(_extra, encoding="utf-8"):
        _line = _line.split("#", 1)[0].strip()
        if not _line:
            continue
        _p = _line if os.path.isabs(_line) else os.path.join(docdir, _line)
        _gen_paths.append(os.path.normpath(_p))
        if not os.path.exists(_p):
            notes.append(f".report_generators lists {_line!r}, which does not "
                         "exist -- a generator that cannot be read is not checked")

#: Any of these taking a long string is prose placed on the canvas. `text` and
#: `annotate` are here because moving the words from a title to an annotation
#: is not a fix, and a helper whose name carries `caption`/`title` counts too.
_IN_IMAGE = ("suptitle", "set_title", "title", "text", "annotate", "figtext")

def _literal_len(node):
    """Length of a string argument, or None if it is not a string at all.

    Handles implicit concatenation (ast folds it into one Constant) and
    f-strings (JoinedStr: sum only the LITERAL parts, since the interpolated
    values are not known here and would otherwise be counted as zero-width).
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return len(node.value), node.value
    if isinstance(node, ast.JoinedStr):
        parts = [v.value for v in node.values
                 if isinstance(v, ast.Constant) and isinstance(v.value, str)]
        return sum(len(x) for x in parts), "".join(parts)
    return None

for _gp in _gen_paths:
    if not os.path.exists(_gp):
        continue
    _gen = os.path.basename(_gp)
    _gsrc = open(_gp, encoding="utf-8").read()
    try:
        _tree = ast.parse(_gsrc)
    except SyntaxError as _e:
        notes.append(f"{_gen}: could not be parsed ({_e}), so rule 18 did not "
                     "check it")
        continue
    for _node in ast.walk(_tree):
        if not isinstance(_node, ast.Call):
            continue
        _f = _node.func
        _name = _f.attr if isinstance(_f, ast.Attribute) else getattr(_f, "id", "")
        _low = _name.lower().lstrip("_")
        if not (_low in _IN_IMAGE or "caption" in _low or "title" in _low):
            continue
        for _arg in _node.args:
            _got = _literal_len(_arg)
            if _got is None:
                continue
            _n, _txt = _got
            if _n > 100:
                bad.append((0, f"{_gen}:{_node.lineno}: {_name}() is given "
                               f"{_n} characters of text ({_txt[:40]!r}...) -- "
                               "that is an explanation, not a label; it belongs "
                               "in the report's prose, not inside the image"))

# --- 19. Definitions register: every metric named in a table header is -------
#     defined, BY NAME, in evidence/definitions.md (R4, 2026-09-06). This
#     checks names only -- it cannot tell a definition is CORRECT, only that
#     one exists for every column a table claims to report. Correctness stays
#     with the single cold read (references/evidence.md).
_STRUCT_COLS = {
    "id", "part", "section", "sections", "model", "models", "arm", "arms",
    "config", "configuration", "setting", "settings", "checkpoint",
    "checkpoints", "name", "notes", "description", "figure", "figures",
    "table", "tables", "subject", "words", "dataset", "run", "seed", "date",
    "source", "category", "class", "page", "index", "item", "method",
    "variant", "group", "when", "why", "where", "status",
}


def _strip_suffix(h):
    """Drop a parenthetical unit/suffix and footnote markers before comparing
    a table header against a definitions-register heading, so 'RMSE (m)' in
    a table matches an 'RMSE' heading (R4 tolerance rule)."""
    h = re.sub(r"\([^)]*\)", "", h)
    h = re.sub(r"[*†‡§]", "", h)
    return h.strip().strip("*").strip()


def _is_metric_like(h):
    h = _strip_suffix(h)
    if not h or not re.search(r"[A-Za-z]", h):
        return False
    return h.lower() not in _STRUCT_COLS


_headers = []
for _i in range(len(lines) - 1):
    _l, _sep = lines[_i].strip(), lines[_i + 1].strip()
    if (_l.startswith("|") and _sep.startswith("|")
            and set(_sep.strip("| ")) <= set("-:| ") and "-" in _sep):
        _cells = [c.strip() for c in _l.strip("|").split("|")]
        _headers.extend(c for c in _cells if c)

_metric_cols = sorted({_strip_suffix(h) for h in _headers if _is_metric_like(h)},
                       key=str.lower)

_reg_index = {}
if _metric_cols:
    _defs_path = os.path.join(docdir, "evidence", "definitions.md")
    if not os.path.exists(_defs_path):
        bad.append((0, "no evidence/definitions.md, but the document has table "
                       f"column(s) that look like metrics ({', '.join(_metric_cols)}) "
                       "-- build the register first (R4, references/evidence.md)."))
    else:
        _defs_text = open(_defs_path, encoding="utf-8").read()
        _reg_raw = re.findall(r"^#{1,6}\s*(.+)$", _defs_text, re.M)
        # A register heading may be indexed by its own text OR by an acronym it
        # declares in parentheses, so `Root Mean Square Error (RMSE)` satisfies a
        # column headed `RMSE`. Without this, rule 22's demand for a proper name
        # would fight rule 19's demand for a name match (2026-09-10).
        _reg_index = {}
        for _h in _reg_raw:
            _reg_index.setdefault(_strip_suffix(_h).lower(), _h)
            for _a in re.findall(r"\(([^)]*)\)", _h):
                _a = _a.strip()
                if _a and " " not in _a:
                    _reg_index.setdefault(_a.lower(), _h)
        _reg_heads = set(_reg_index)
        _missing = [c for c in _metric_cols if c.lower() not in _reg_heads]
        if _missing:
            bad.append((0, "evidence/definitions.md has no heading for: "
                           f"{', '.join(_missing)} -- every metric/score column "
                           "header must be defined there before this builds."))
else:
    notes.append("no table column looked like a metric/score name -- rule 19 "
                 "(definitions register) skipped.")

# --- 20. Pre-draft gate: see scripts/predraft_gate.sh (called from the shell
#     below, so the register is checked with the same code before and after
#     drafting rather than in two drifting copies).

# --- 21. Procedural voice: a findings document, not a user manual (NOTE). -----
#     "We evaluate under...", "We therefore report the panel..." -- nine such
#     constructions shipped in a four-page note. Owner: "Don't say that we report
#     this or that. Just say what is a good practice. This is not about a user
#     manual of something that we have developed. This is about explaining what
#     we have found." A NOTE, not a refusal: first person is legitimate in a
#     methods sentence, and it is the COUNT that shows a document has slipped
#     into narrating its authors' afternoon.
#     An adverb between the pronoun and the verb is the commonest form and was
#     the shipped one ("We therefore report the panel"), so it is matched too.
_PROC = re.compile(r"\bwe\s+(?:\w+ly\s+|therefore\s+|then\s+|also\s+|thus\s+|"
                   r"here\s+)?(report|use|evaluate|score|train|set|call|derive|"
                   r"compute|apply|run|present|show)\b", re.I)
_proc_hits, _in_fence = [], False
for _i, _l in enumerate(lines, 1):
    if _l.lstrip().startswith("```"):
        _in_fence = not _in_fence
        continue
    if _in_fence:
        continue
    # finditer, not search: the shipped case had TWO constructions in one
    # sentence pair on one line, and a per-line search counted one of them.
    for _m in _PROC.finditer(_l):
        _proc_hits.append((_i, _m.group(0)))
if _proc_hits:
    _shown = ", ".join(f"line {n} ({t})" for n, t in _proc_hits[:6])
    _more = f", +{len(_proc_hits) - 6} more" if len(_proc_hits) > 6 else ""
    notes.append(f"{len(_proc_hits)} first-person procedural construction(s) -- "
                 f"{_shown}{_more}. A findings document says what is true and what "
                 f"was found, not what its authors did.")

# --- 22. Metric names are PROPER names with acronyms (B1, 2026-09-10). --------
#     Shipped: `spread / error`, `coverage error (points)`, `normalised RMSE`.
#     Owner: "terrible metric names. Should be proper & capitalised for example
#     Spred Skill Ratio (SSR)". Two halves: the column header is capitalised
#     (document side), and the register EXPANDS an acronym (register side), so
#     the proper name exists somewhere a reader can reach it.
_ACRONYMISH = re.compile(r"^(?:[A-Z]{2,6}|[a-z][A-Z]{1,5})$")
_LOWER_OK = re.compile(r"^(?:[a-z]{1,2}(?:[-_]value)?|[a-z][A-Z].*)$")
for _h in sorted({_strip_suffix(h) for h in _headers if _is_metric_like(h)},
                 key=str.lower):
    _first = re.search(r"[A-Za-z]", _h)
    if _first and _first.group(0).islower() and not _LOWER_OK.match(_h):
        bad.append((0, f"table column {_h!r} is not a proper metric name -- give it "
                       "a capitalised proper name and, if it has one, its acronym "
                       "(e.g. 'Spread-Skill Ratio (SSR)'), verified against source "
                       "rather than coined."))
    if _metric_cols and _ACRONYMISH.match(_h):
        _head_raw = _reg_index.get(_h.lower())
        if _head_raw:
            # The expansion counts wherever the register puts it -- in the
            # heading, or on any line of the register that names the acronym.
            # Measured 2026-09-10 against a real register: it defined ARFC in a
            # naming section ("**ARFC** -- Adaptive-Rank Factor Covariance") and
            # headed the column entry with the bare acronym, which a
            # heading-only check called a defect. What identifies an expansion
            # is a RUN of consecutive capitalised words, not a count of them --
            # "in Table 4 by Model A" has two capitalised words and no run.
            _run = re.compile(r"\b[A-Z][A-Za-z-]{2,}(?:\s+[A-Z][A-Za-z-]{2,})+")
            _where = [_head_raw] + [l for l in _defs_text.split("\n")
                                    if re.search(rf"\b{re.escape(_h)}\b", l)]
            _found = any(_run.search(re.sub(rf"\b{re.escape(_h)}\b", "", w))
                         for w in _where)
            if not _found:
                bad.append((0, f"the definitions register never expands the "
                               f"acronym {_h!r} (its heading is {_head_raw!r}) -- "
                               "write the proper name out somewhere in the "
                               f"register (the form is 'Proper Name In Capitals "
                               f"({_h})'), so a reader meeting {_h!r} in a table "
                               "can find out what it stands for."))

# --- 23. A unit word must not collide with the document's own vocabulary. -----
#     `Coverage Error (points)` meant PERCENTAGE points, in a document using
#     "points" throughout for GRID points. Owner: "What is Coverage Error
#     (points)? What is points?" Two tiers: colliding with a DEFINED term is
#     exact and refuses; colliding with a compound noun in the prose is a
#     heuristic and notes.
_units = set()
for _h in _headers:
    for _u in re.findall(r"\(([^)]*)\)", _h):
        _u = _u.strip().lower()
        if re.fullmatch(r"[a-z][a-z-]{2,}", _u):
            _units.add(_u)
if _units:
    _prose = "\n".join(l for l in lines if not l.strip().startswith(("|", "#", "<!--")))
    _defined = set()
    _dp = os.path.join(docdir, "evidence", "definitions.md")
    if os.path.exists(_dp):
        _defined = {re.sub(r"\([^)]*\)", "", h).strip().lower()
                    for h in re.findall(r"^#{1,6}\s*(.+)$",
                                        open(_dp, encoding="utf-8").read(), re.M)}
    for _u in sorted(_units):
        if _u in _defined or _u.rstrip("s") in _defined:
            bad.append((0, f"the unit {_u!r} in a table header is also a DEFINED "
                           "term in this document -- a reader cannot tell which "
                           "sense a header means. Rename the unit (e.g. "
                           "'percentage points (pp)') or the term."))
            continue
        _comp = re.findall(r"\b([A-Za-z][A-Za-z-]{2,})\s+" + re.escape(_u) + r"\b",
                           _prose)
        _comp = [w for w in _comp if w.lower() not in {"the", "of", "in", "and",
                                                       "per", "these", "those"}]
        if _comp:
            notes.append(f"unit {_u!r} in a table header also appears in the prose "
                         f"as {_comp[0].lower()} {_u} -- if those are different "
                         f"things, the header needs the qualifier too.")


for note in notes:
    print(f"GUARD: note — {note}", file=sys.stderr)
for n, why in bad:
    print(f"GUARD: {f'line {n}: ' if n else ''}{why}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# --- 20. The pre-draft register (A1-A3, A7, B3; see scripts/predraft_gate.sh).
#     Fires once the document has entered the loop -- a section list exists
#     (step 0b is done, so the gate that sits right after it is due) or the
#     document embeds a figure (the class the asset inventory and the contact
#     sheet exist for). A bare fixture with neither is not a report and is
#     skipped with a notice rather than a refusal.
SKILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCDIR_G="$(cd "$(dirname "$DOC")" && pwd)"
if [ -f "$DOCDIR_G/SECTION_LIST.md" ] || grep -qE '^!\[' "$DOC"; then
  bash "$SKILL_ROOT/scripts/predraft_gate.sh" "$DOC" || fail=1
else
  echo "GUARD: note — no SECTION_LIST.md and no embedded figure, so the pre-draft" >&2
  echo "GUARD:   gate (rule 20) is not enforced on this document." >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "GUARD: research-report contract violated — fix the lines above." >&2
  exit 1
fi
echo "GUARD: clean."
