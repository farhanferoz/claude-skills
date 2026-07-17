---
name: research-report
description: Author or revise a shareable technical note or research report as a self-contained book chapter, then enforce it with a hard contract guard, a pdflatex book-chapter build, and a mandatory fresh-reader cold-read gate. Use when writing or revising a research report, model note, derivation writeup, experiment/results note, or technical note meant to be shared with colleagues; when asked to make a document self-contained, readable cold, or free of code references and jargon; or when finalizing or reviewing such a document before sharing.
---

# Research report

Write a shareable technical note so a reader **with no project context and no code access** can follow it start to finish. The recurring failure this skill prevents: a self-audit from inside the working context silently fills the gaps, so undefined terms, code references, asserted math, and jargon keep shipping. The fix is a loop with two hard gates the author cannot fool — a grep guard and a fresh-context cold reader.

## The loop

Copy this checklist and track it:

- [ ] 0. Read `references/contract.md` (and `references/doc-standard.md`) **before drafting**.
- [ ] 1. Draft or revise the report against the contract.
- [ ] 1b. **Reconcile the artifact ledger** (contract rule 7): list every results table and figure produced for this report; each is either surfaced (as a table/figure) or consciously excluded with a reason. Declare the figure namespace in a `<!-- report-figures: ... -->` manifest so the guard enforces it. Nothing computed vanishes into prose.
- [ ] 2. Guard: `bash scripts/report_guard.sh <doc.md>` → fix every violation → re-run until it prints `GUARD: clean.`
- [ ] 3. Build: `bash scripts/build_report.sh <doc.md>` → produces `<doc>.pdf`. Confirm 0 unresolved cross-references, **and skim the rendered tables** — wide/long-cell tables are the recurring break (the filter sizes columns, but verify no column wrapped mid-word).
- [ ] 4. Cold-read gate (MANDATORY): spawn a fresh subagent with `references/cold-reader-prompt.md`, pointed at the **rendered PDF only**. Triage its findings.
- [ ] 5. Iterate: fix flagged items; for any flagged word, add it to the `DENY` list in `scripts/report_guard.sh`; rebuild; re-run the gate until it returns no blockers.

The guard (step 2) catches the mechanical rules; the cold reader (step 4) catches the semantic ones — undefined terms, cryptic passages, load-bearing math asserted rather than derived. Neither replaces the other. The author's own re-read counts for nothing here: it is exactly the read that already missed the gaps.

## Step 1 — draft against the contract

`references/contract.md` is the full genre contract. The load-bearing rules:

1. **No code references** — no file paths, function/class names, config keys, `.py`/`.yaml`, CLI commands. Describe *what the thing does*, not *where it lives*.
2. **Plain words** — no coined or fancy terms. Define any genuinely-standard technical term in plain language at first use.
3. **Define every named object inline, with its formula**, at the point of first use — not in a distant glossary, not by name only.
4. **Derive load-bearing math** — the bound, loss, estimator, or update the result rests on gets a real derivation (an appendix if long) *and* a sentence on why it is the right thing to optimise. A name plus a one-line formula is not enough.
5. **Math is typeset as math** — display math for anything load-bearing; ASCII LaTeX inside `$...$`; never a formula inside a code span.
6. **Cite real sources, verified this session, only where they earn it** — keep them in `assets/references.bib` (or a `references.bib` beside the document).
7. **Show the evidence you have (completeness).** Every computed result the conclusion rests on appears as a table or figure, not a prose paraphrase of its headline cell; every figure generated is embedded and explained; every idea discussed earns a figure (an illustrative one — a cost curve, an economics bar — is fine where there was no back-test, if labelled as such). Declare the figure namespace in a `<!-- report-figures: ... -->` manifest. This is the gap that ships a thin report past a clean clarity check.

See `references/examples.md` for before/after fixes drawn from a real rewrite.

## Step 3 — build

`build_report.sh` runs the guard, then pandoc with the bundled book-chapter template, `--citeproc`, and the proportional-table-width filter. Notes:

- The engine is **pdflatex** (the template's Palatino/Helvetica packages are Type1; xelatex *silently* falls back to Latin Modern — wrong fonts, no error).
- Bibliography: a `references.bib` next to the document is used if present, else the bundled one. Every entry must be verified this session (contract rule 6).
- After building, check the rendered PDF for `??` (unresolved `\ref`/`\eqref`) — pandoc resolves cross-references across passes, but a typo in a label still ships as `??`.

## Step 4 — the cold-read gate (mandatory)

Spawn a **fresh subagent** (general-purpose) using the prompt in `references/cold-reader-prompt.md`. Fill in the absolute PDF path and page count. Constraints that make it work:

- It reads the **rendered PDF**, never the markdown source — in the source, citations and cross-references are still unresolved tokens, and the typeset math (where ambiguous glyphs hide) is not visible.
- It has **no project context and no code access** — it is told not to open any other file.
- It returns lists of: undefined terms/symbols, cryptic/unfollowable passages, load-bearing math asserted-not-derived, inconsistencies.

Triage every finding. Verify before acting — a fresh reader can misread a glyph (if two independent readers misread the *same* symbol, that is signal the notation is ambiguous and should change, even if "technically correct"). Then fix in the source and rebuild.

## Step 5 — grow the denylist

Whenever the cold reader flags a word as jargon, add its stem to the `DENY=` pipe-list in `scripts/report_guard.sh`. The same fancy term then can never ship again — the guard hard-fails on it. This is how the mechanical gate absorbs what the human gate finds.

## Placement

This skill is self-contained: the contract, guard, template, bib, and cold-reader prompt all live under the skill root and resolve relative to it, so it works in any repository. The report's markdown and PDF live wherever the author keeps them.
