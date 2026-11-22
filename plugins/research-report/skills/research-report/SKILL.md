---
name: research-report
description: >-
  Author or revise a shareable technical note or research report as a self-contained
  book chapter, with a contract guard, a pdflatex build and a fresh-reader cold-read
  gate. Use when writing or revising a research report, model note, derivation
  writeup, experiment/results note, or technical note for colleagues; when asked to
  make a document self-contained or readable cold; or when finalizing one before
  sharing.

---

# Research report

Write a shareable technical note so a reader **with no project context and no
code access** can follow it start to finish. The recurring failure: a
self-audit from inside the working context fills gaps silently, so undefined
terms, code references, asserted math, and jargon keep shipping. The fix: a
loop with hard gates the author cannot fool — a definitions register, a grep
guard, a render review, a fresh-context cold reader — each backed by a
refusal, not a sentence. Incidents behind each rule: `CHANGELOG.md`.

**`GUARD: clean` is a floor, never the bar** — it says nothing about depth or
whether anyone can follow the document; the last word belongs to the cold
read. **Time pressure compresses scope, never the gate set** — write less,
narrow scope, hand over less; never skip a step. If the schedule genuinely
does not fit, name the gate you propose to drop and let whoever asked decide.

## The loop

Copy this checklist, track it:

- [ ] 0. **Preflight** (R8): `bash scripts/build_report.sh --preflight` —
  checks the toolchain and a 3-line test build; fix before drafting. Read
  `contract.md` first; `structure.md` at 0b; `doc-standard.md`/
  `owner-presentation-rules.md` only when needed.
- [ ] 0a. **Not your draft? Run the definition sweep before any gate**: from
  source, confirm every metric/model/constant/table/headline-number is
  actually stated, not assumed known. Authoring work, not a cold-read finding.
- [ ] 0b. **Choose the spine** (`structure.md` rule 1), declare
  `<!-- report-structure: ... -->`, write `SECTION_LIST.md` with each
  section's budget — enforced unconditionally. Sign-off is OFF by default
  (never infer it from a forward-leaning reply); `REPORT_REQUIRE_SIGNOFF=1`
  makes a missing `<!-- agreed-by: ... -->` fatal.
- [ ] 0b+. **Pre-draft gate** — `bash scripts/predraft_gate.sh <report dir>`:
  subject in one sentence, each contribution's role in one sentence, an
  inventory of every existing figure with its **point count**, a contact
  sheet for any figure chosen from a set (`evidence.md`). Refuses; the guard
  re-runs it on the draft. **Highest return in this loop** — it is where four
  rounds of churn otherwise go.
- [ ] 0c. **Evidence gate** (`evidence.md`): claims register, supersession
  ledger, figure inventory, and — R4 — `evidence/definitions.md` (one heading
  per named metric/model/constant, from source). The guard refuses to build
  on a table metric column with no matching heading (name match only). Draft
  past an authoring gap; never build past one.
- [ ] 1. Draft or revise against the contract below; per finished section
  report `§X: N words of M, tables i/j, figures k/l`.
- [ ] 1b. Reconcile the artifact ledger (rule 7): every table/figure surfaced
  or consciously excluded; declare `<!-- report-figures: ... -->`.
- [ ] 2. Guard: `bash scripts/report_guard.sh <doc.md>` → fix → re-run until
  `GUARD: clean.`
- [ ] 2b. Numbers: `python3 scripts/verify_numbers.py <doc.md>` — **re-run
  after every rewrite**; a rewrite invalidates the pass, and the hand-over
  gate refuses on a stale one.
- [ ] 3. Build: `bash scripts/build_report.sh <doc.md>` → `<doc>.pdf`.
- [ ] 3b. **Render review** (R5) — open every figure/table page against rule
  10 (**judge legibility at ≥150 dpi, never below**), then
  `bash scripts/mark_rendered.sh <doc.md> <pages>`. Every build
  resets this to UNREVIEWED; hand-over refuses until re-marked.
- [ ] 4. **Cold-read gate (mandatory).** Steps 0a/3b make one read enough.
  Spawn a fresh subagent on **Opus** with `cold-reader-prompt.md`, pointed at
  the rendered PDF and an absolute output path
  `<doc dir>/evidence/coldread_<n>.md` — it writes findings there (the result
  channel truncates long replies) and replies one line. Record:
  `bash scripts/record_coldread.sh <doc.md> <findings-file>` (refuses under
  2 KB). **Two reads is the ceiling** — a third is refused unless
  `REPORT_ALLOW_THIRD_READ=1`, stated in the ledger.
- [ ] 5. Iterate: jargon → guard's `DENY` list; superseded number →
  `retracted_values.txt`; anything else → name the *class*, add a rule.
  Rebuild `--draft` while iterating; re-run until `## BLOCKERS` in the last
  recorded read is empty (`## OTHER` → `FIX_LEDGER.md` as SHOULD, never
  gates). **>10 blockers on read 1 → cut scope**, not fix-everything.
- [ ] 6. Hand over: `bash scripts/build_report.sh --shareable <doc.md>` —
  refuses on an open ledger row, a stale cold read, or an unreviewed render.

The author's own re-read counts for nothing: it is exactly the read that
already missed the gaps.

## Draft against the contract

`contract.md` is the full genre contract. Load-bearing rules:

1. **No code references** — no paths, class/function names, config keys,
   extensions, CLI commands. What the thing does, not where it lives.
2. **Plain words** — define any standard technical term at first use.
3. **Define every named object inline, with its formula**, at first use — the
   rule that decides loop length, or the cold reader enforces it instead.
4. **Derive load-bearing math** — the bound/loss/estimator/update the result
   rests on gets a real derivation and why it is the right thing to optimise.
5. **Math is typeset as math** — never a formula in a code span.
6. **Cite real sources, verified this session** — `assets/references.bib` or a
   sibling `references.bib`.
7. **Show the evidence you have** — every result the conclusion rests on is a
   table or figure, never a prose paraphrase of its headline cell.

A **short note** — two to six pages, no numbered sections — is a mode of this
genre, not another one: `short-note.md` for its four deltas, and build with
`--note`. See `examples.md` for before/after fixes.

## Build, cold read, and the CLASS rule

Engine is **pdflatex** (xelatex silently falls back to the wrong fonts). The
cold reader reads the **rendered PDF only** — no context, no code access —
returning undefined terms, cryptic passages, math asserted not derived,
inconsistencies, under-shown evidence, organisation/legibility problems, as
`## BLOCKERS` (ranked, max 10) then `## OTHER` (`cold-reader-prompt.md`).
Triage by reproducing a complaint, never by reasoning about it.

**A finding does not close until its class has a mechanical backstop, or a
recorded reason it cannot have one** — fixing instances only makes review feel
endless. ⚠ Verify a new guard rule both fires on the defect *and* is silent
once fixed — `report_guard.sh` rebinds `body` inside rule 14, so never trust a
name an earlier rule may have mutated. Same turn: presentation rulings go in
`references/owner-presentation-rules.md`.

## Report sessions and updates

**Dedicated authoring session (R6).** A report session's first instruction is
the report brief — document, section list, register and evidence paths, never
"resume the plan"; `checkpoint` writes it as a `### Report session brief`
block in `RESUME.md`.

**Updating an existing report** — the unit of update is the section, never the
line; trust comes from re-running the gates on the whole document, not from
careful editing:
- **U0** — delta the evidence first: new/superseded register rows, superseded
  values also into `evidence/retracted_values.txt`. No prose yet.
- **U1** — triage against the spine: (a) new sibling subject — sibling budget;
  (b) changed numbers, same story — regenerate and re-author the affected
  sections; (c) the answer changed — from-scratch for that spine. Doing (c)
  with (b)'s tools is what produces garbage. Re-sign the section list (0b).
- **U2** — re-author affected sections **whole**, never patch; untouched
  sections carry over and are listed as such.
- **U3** — re-certify globally: guard, build, render review, cold read of the
  **whole** PDF (not the diff), then step 6.
- A foreign report gates on artifacts, not provenance: adopt it (rebuild the
  section list and registers) if sound, else treat as case (c).

## The fix ledger

Every review-round issue becomes a `FIX_LEDGER.md` row: complaint, agreed fix,
where it landed, how it was checked. The build refuses while any row is OPEN.
A row closes on verification, not effort — `OPEN — claimed fixed, not
verified` is still open, the most important kind.

## Placement

Self-contained: contract, guard, template, bib and prompts resolve relative to
the skill root; the report lives wherever the author keeps it.
