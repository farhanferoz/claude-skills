# Sources & provenance

This skill packages a research-report authoring loop that was built and calibrated against a real rewrite (a 19-page model note the loop caught real defects in across two cold-read rounds). The tooling is bundled verbatim from its calibration source so the skill is self-contained and portable.

## Bundled artifacts

| Skill file | Calibration source | Role |
|---|---|---|
| `references/contract.md` | research-report genre contract | the 6+1 rules; enforcement section adapted to skill-relative paths |
| `references/doc-standard.md` | base research-doc authoring standard | source-first, define-before-narrate, math-as-math, whole-doc audit, hard guards |
| `scripts/report_guard.sh` | hard grep guard | code-refs, denylist, math-in-backticks, section-0, bare √, thematic rules — verbatim |
| `assets/book_chapter.tex` | pdflatex book-chapter template | mathpazo/helvet/microtype, numbered equations, float-here figures — verbatim |
| `assets/references.bib` | verified shared bibliography | starter entries (all checked against source); per-report `references.bib` overrides |
| `assets/auto_table_widths.lua` | pandoc filter | proportional table column widths — verbatim |
| `references/cold-reader-prompt.md` | refined across two real gate runs | the fresh-reader gate prompt + triage guidance |
| `references/examples.md` | the real rewrite | before/after fixes for rules 1–4 and a gate-driven notation change |

## Decisions

- **Self-contained, user-global.** All tooling resolves relative to the skill root, so the loop runs in any repository. The calibration source repository keeps its own copy; this skill is the packaged, portable version.
- **pdflatex, not xelatex.** The template's Type1 fonts fall back silently under xelatex; the build script pins pdflatex.
- **Per-report bibliography.** The build prefers a `references.bib` beside the document over the bundled starter, so each report carries its own verified citations (contract rule 6).
- **The denylist is mutable state.** `scripts/report_guard.sh`'s `DENY=` list grows as the cold reader flags new jargon — that is the mechanism by which the same fancy word never ships twice.

## Validation

- Guard self-test: `bash scripts/selftest.sh` (planted violations fail, clean passes).
- End-to-end: a planted-flaw report through guard + build + cold-read gate confirms the gate catches what the guard cannot (undefined term, asserted math).
- Regression: guard + build + cold-read on the calibration model note returns no blockers.
