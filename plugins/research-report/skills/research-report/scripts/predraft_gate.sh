#!/usr/bin/env bash
# Pre-draft gate: the decisions that must be MADE and the assets that must be
# SURVEYED before a word is drafted.
#
# WHY THIS EXISTS, and it is the most expensive lesson the skill has recorded.
# The 2026-09-10 short-note session cost roughly a dozen owner review rounds,
# four of them full rewrites. Almost none of that was a writing failure:
#   * the SUBJECT was wrong for four rounds -- the note was drafted as a
#     monograph on one model when the subject was the capability, with that
#     model as one contribution to it. The section list had been agreed, and it
#     was agreed against the wrong subject, so it agreed to the wrong document.
#   * a regional-coverage figure was BUILT FROM SCRATCH with 2 points per curve
#     while the same repository already held the same measurement at 4 points
#     and at 7, and a 20-level curve sitting in the data. Two minutes of `ls`.
#   * a case figure took FOUR rounds of propose-and-refuse because the six
#     candidates were never shown side by side; the owner eventually picked one
#     from a directory they had never been shown.
# Prose telling an author to check what exists was already in the contract and
# was still missed. So this is a refusal.
#
# Usage:
#   bash predraft_gate.sh <report-dir>    # before drafting: the register alone
#   bash predraft_gate.sh <doc.md>        # with a draft: also provenance + naming
#
# report_guard.sh calls the second form, so the gate cannot be skipped by
# starting to write.
set -uo pipefail

TARGET="${1:?usage: predraft_gate.sh <report-dir|markdown-file>}"
if [ -d "$TARGET" ]; then
  DOCDIR="$(cd "$TARGET" && pwd)"; DOC=""
elif [ -f "$TARGET" ]; then
  DOCDIR="$(cd "$(dirname "$TARGET")" && pwd)"; DOC="$TARGET"
else
  echo "PREDRAFT: no such file or directory: $TARGET" >&2; exit 2
fi

python3 - "$DOCDIR" "$DOC" <<'PY'
import os, re, sys

docdir, doc = sys.argv[1], sys.argv[2]
reg_path = os.path.join(docdir, "evidence", "predraft.md")
bad, notes = [], []


def sections_of(text):
    """{normalised heading: body} for every heading in a markdown text."""
    out, cur, buf = {}, None, []
    for line in text.split("\n"):
        m = re.match(r"^#{1,6}\s*(.+?)\s*$", line)
        if m:
            if cur is not None:
                out[cur] = "\n".join(buf)
            cur, buf = m.group(1).strip().lower(), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        out[cur] = "\n".join(buf)
    return out


def rows_of(body):
    """Header cells and data rows of the first markdown table in a body."""
    lines = [l.strip() for l in body.split("\n")]
    for i in range(len(lines) - 1):
        if (lines[i].startswith("|") and lines[i + 1].startswith("|")
                and set(lines[i + 1].strip("| ")) <= set("-:| ") and "-" in lines[i + 1]):
            head = [c.strip().lower() for c in lines[i].strip("|").split("|")]
            data = []
            for l in lines[i + 2:]:
                if not l.startswith("|"):
                    break
                data.append([c.strip() for c in l.strip("|").split("|")])
            return head, data
    return [], []


if not os.path.exists(reg_path):
    print("PREDRAFT: refused -- no evidence/predraft.md.", file=sys.stderr)
    print("PREDRAFT:   Before drafting, write it with four headings:", file=sys.stderr)
    print("PREDRAFT:     ## Subject            one sentence: what this document is about",
          file=sys.stderr)
    print("PREDRAFT:     ## Contributions      table | contribution | role | carried in |",
          file=sys.stderr)
    print("PREDRAFT:     ## Asset inventory    table with a 'points' column, one row per",
          file=sys.stderr)
    print("PREDRAFT:                           existing figure/curve you could reuse",
          file=sys.stderr)
    print("PREDRAFT:     ## Figure selection   the contact sheet, or the one-line refusal",
          file=sys.stderr)
    print("PREDRAFT:   Detail and the incidents: references/evidence.md, "
          "'The pre-draft register'.", file=sys.stderr)
    sys.exit(1)

reg = open(reg_path, encoding="utf-8").read()
secs = sections_of(reg)


def find(*names):
    for k, v in secs.items():
        if any(re.search(n, k) for n in names):
            return k, v
    return None, None


# --- A1. The subject, decided, in one sentence. -------------------------------
_, subject = find(r"^subject\b")
if subject is None:
    bad.append("no '## Subject' heading -- state in ONE sentence what the document "
               "is about, and get that agreed BEFORE the section list. A section "
               "list agreed against the wrong subject agrees to the wrong document.")
else:
    body = " ".join(l.strip() for l in subject.split("\n")
                    if l.strip() and not l.strip().startswith(("<!--", "|", ">")))
    if not body:
        bad.append("'## Subject' is empty -- one sentence, not a placeholder.")
    else:
        # Sentence count, tolerant of decimals and abbreviations like 'e.g.'.
        enders = len(re.findall(r"[.!?](?:\s|$)", re.sub(r"\d\.\d", "00", body)))
        if len(body.split()) > 40 or enders > 1:
            bad.append(f"'## Subject' is {len(body.split())} words in "
                       f"{max(enders,1)} sentence(s) -- the budget is ONE sentence "
                       "of at most 40 words. A subject you cannot state in one "
                       "sentence has not been decided yet.")

# --- A1b. Each contribution's ROLE in that subject, in one sentence. ----------
_, contribs = find(r"^contribution")
contributions = []          # (name, carried_in)
if contribs is None:
    bad.append("no '## Contributions' heading -- one row per named contribution, "
               "with its ROLE IN THE SUBJECT in one sentence. Naming the "
               "contributions without their roles is what produced a monograph on "
               "one of them.")
else:
    head, data = rows_of(contribs)
    if not data:
        bad.append("'## Contributions' has no table rows -- "
                   "| contribution | role | carried in |, one row each.")
    else:
        def col(*pats, default=None):
            for i, h in enumerate(head):
                if any(re.search(p, h) for p in pats):
                    return i
            return default
        ci, ri = col(r"contribution|name"), col(r"role|its role")
        wi = col(r"carried|section|movement")
        if ci is None or ri is None:
            bad.append(f"'## Contributions' columns are {head} -- it needs a "
                       "'contribution' column and a 'role' column.")
        else:
            for r in data:
                if len(r) <= max(ci, ri):
                    continue
                name, role = r[ci].strip(" *"), r[ri].strip()
                if not name:
                    continue
                if len(role.split()) < 4:
                    bad.append(f"contribution {name!r} has no role sentence -- say "
                               "in one sentence what it contributes to the subject.")
                carried = r[wi].strip() if (wi is not None and len(r) > wi) else ""
                contributions.append((name, carried))

# --- A2. The asset inventory: what already exists, with its point count. ------
_, inv = find(r"asset inventory|^assets\b|^inventory\b")
if inv is None:
    bad.append("no '## Asset inventory' heading -- enumerate EVERY existing figure "
               "and curve file you could reuse, with its point count, before "
               "drawing anything. A 2-point curve was built from scratch beside a "
               "7-point one that already existed.")
else:
    head, data = rows_of(inv)
    searched = re.search(r"^\s*searched:", inv, re.M | re.I) and \
        re.search(r"none found", inv, re.I)
    if not data and not searched:
        bad.append("'## Asset inventory' has no rows -- list the candidates, or "
                   "record the search that found nothing as "
                   "'searched: <where> -- none found'.")
    elif data and not any(re.search(r"point", h) for h in head):
        bad.append(f"'## Asset inventory' columns are {head} -- it needs a 'points' "
                   "column (points per curve, levels, rows). The point count IS the "
                   "comparison that decides whether to reuse or redraw.")

# --- A3. A figure chosen from a set is chosen from a contact sheet. -----------
_, sel = find(r"figure selection|^selection\b")
if sel is None:
    bad.append("no '## Figure selection' heading -- when a figure is SELECTED from "
               "a set, show every candidate on one contact sheet and let the owner "
               "choose. Proposing one at a time cost four rounds. If nothing is "
               "selected from a set, say so in that heading, in those words.")
else:
    declared_none = re.search(r"no figure was selected from a set", sel, re.I)
    sheets = [p for p in re.findall(r"[\w./-]+\.(?:png|pdf|jpg|jpeg)", sel)]
    live = [p for p in sheets
            if os.path.exists(p if os.path.isabs(p) else os.path.join(docdir, p))]
    if not declared_none and not live:
        missing = f" (named but missing: {', '.join(sheets)})" if sheets else ""
        bad.append("'## Figure selection' names no contact sheet that exists"
                   f"{missing} -- give the path to the sheet the choice was made "
                   "from, or state 'no figure was selected from a set.'")

# --- With a draft in hand: B3 provenance, and A7 naming. ---------------------
if doc and os.path.exists(doc):
    text = open(doc, encoding="utf-8").read()
    figs = [m.group(1).split()[0].strip('"')
            for m in re.finditer(r"^!\[[^\]]*\]\(([^)]+)\)", text, re.M)]

    # --- B3. A borrowed figure carries text no prose grep can see. -----------
    #     Twice in one session: a legend reading AD64/CNS64, and a title bar
    #     reading a cell code AND a metric key -- both baked into the PNG while
    #     every grep over the markdown came back clean. A figure this report's
    #     own scripts drew is covered by rule 18; anything else must be declared
    #     as inspected, or redrawn from the source values.
    gen_names = ["make_figures.py", "present_grid.py"]
    extra = os.path.join(docdir, ".report_generators")
    if os.path.exists(extra):
        for line in open(extra, encoding="utf-8"):
            line = line.split("#", 1)[0].strip()
            if line:
                gen_names.append(line)
    gen_text = ""
    for g in gen_names:
        p = g if os.path.isabs(g) else os.path.join(docdir, g)
        if os.path.exists(p):
            gen_text += open(p, encoding="utf-8", errors="replace").read()
    _, prov = find(r"figure provenance|^provenance\b")
    prov = prov or ""
    undeclared = []
    for f in figs:
        base = os.path.basename(f)
        if base and base in gen_text:
            continue                      # drawn here; rule 18 already reads it
        row = [l for l in prov.split("\n") if base and base in l]
        if not row or not any(re.search(r"inspected", l, re.I) for l in row):
            undeclared.append(f)
    if undeclared:
        bad.append("figure(s) not drawn by a script in this report directory and "
                   f"not declared as inspected: {', '.join(undeclared)} -- add a "
                   "'## Figure provenance' row for each saying where it came from "
                   "and that its EMBEDDED TEXT was inspected for internal codes, "
                   "or redraw it from its source values. No grep over the markdown "
                   "can see inside an image.")

    # --- A7. A section describing a contribution names it. -------------------
    doc_secs = sections_of(text)
    for name, carried in contributions:
        pat = re.compile(re.escape(name), re.I)
        total = len(pat.findall(text))
        if total == 0:
            bad.append(f"contribution {name!r} is declared in the pre-draft "
                       "register and is NEVER NAMED in the document.")
            continue
        if carried:
            key = re.sub(r"[^a-z0-9 ]", " ", carried.lower())
            key = " ".join(key.split())
            hits = [h for h in doc_secs
                    if key and key in re.sub(r"\s+", " ",
                                             re.sub(r"[^a-z0-9 ]", " ", h))]
            if not hits:
                notes.append(f"contribution {name!r} declares 'carried in' "
                             f"{carried!r}, which matches no heading in the "
                             "document -- update the register or the heading.")
            else:
                for h in hits:
                    if not pat.search(doc_secs[h]):
                        bad.append(f"the section {h!r} is where {name!r} is "
                                   "carried, and it never names it -- a paragraph "
                                   "claiming a novelty that names neither the "
                                   "model nor the scheme is the defect this "
                                   "refuses.")
        per_sec = [(h, len(pat.findall(b))) for h, b in doc_secs.items()]
        shown = ", ".join(f"{h}: {c}" for h, c in per_sec if c) or "nowhere"
        notes.append(f"mentions of {name!r} per section -- {shown}")

for n in notes:
    print(f"PREDRAFT: note -- {n}", file=sys.stderr)
for b in bad:
    print(f"PREDRAFT: {b}", file=sys.stderr)
if bad:
    print("PREDRAFT: refused.", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
