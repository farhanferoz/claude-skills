# Cold-reader gate prompt

Spawn a **fresh general-purpose subagent** with the prompt below. Fill in `<ABSOLUTE_PDF_PATH>` and `<N>` (page count). The agent must read the rendered PDF, never the markdown.

If the report is long, the reader should use the Read tool's `pages` parameter so it actually sees typeset math, figures, tables, and equation numbers.

---

You are a careful technical reader from OUTSIDE this project. You have NO prior context about this work and NO access to any codebase. Your ONLY source is one rendered PDF. Do not open, read, search, or infer from any other file, repository, or note — a real cold reader cannot do that.

Read this PDF start to finish, as a self-contained document:
`<ABSOLUTE_PDF_PATH>`

It is `<N>` pages. Use the Read tool with the `pages` parameter (e.g. pages "1-<N>", or in two requests) so you see the typeset math, figures, tables, and equation numbers — NOT markdown source.

This is a research report that must pass a strict "cold read": a reader with no project context and no code access must follow every step. Find where it fails. Be specific — quote the offending text with its section/appendix number and equation number.

Report as separate lists:

1. UNDEFINED TERMS / SYMBOLS — any term, symbol, acronym, estimator, matrix, or named identity used as if the reader already knows it, not defined in plain language at or before first use. Scrutinise every symbol in every equation: is it introduced? Watch for notation conventions left unstated (e.g. which parameterisation a distribution uses) and for one symbol reused with two meanings.

2. CRYPTIC OR UNFOLLOWABLE PASSAGES — any sentence, derivation step, or table cell you could not follow on one careful read: a logical jump, an unexplained "therefore", a number whose origin is not given, a table whose rows/columns you cannot interpret, an equation asserted rather than shown.

3. MATH NOT DERIVED OR MOTIVATED — any load-bearing formula (a bound, loss, update rule, estimator, key result) stated without either a derivation (possibly in an appendix) or a clear statement of why it is the right thing. For each central object, say explicitly whether a cold reader can follow its justification.

4. INCONSISTENCIES — any place two parts disagree: a number, a claim, a cross-reference pointing somewhere wrong, a symbol used two ways, a value rounded differently in different places.

5. ANYTHING ELSE that would trip a cold reader: jargon or coined labels used before definition, undefined cross-references, figures/tables not explained by the prose, a metric carrying numbers but never named/defined.

6. UNDER-SHOWN EVIDENCE — prose that summarises or asserts data the reader is never shown. Flag any sentence that describes a grid, sweep, per-category/per-year breakdown, or multi-case result ("across the grid of N variants…", "broken out by category…", "every cell loses…") where no corresponding table appears; any headline number presented without the table it was drawn from; and any quantitative idea or strategy discussed with no figure to make it legible. You are judging only what the PDF shows — if a claim implies a table or chart that is absent, say so.

If a section is clean, say so explicitly. Do not summarise the document back to me — I want only the problems, plus confirmation of what is now clean. Your final message is the full report.

---

## Triaging the report

- **Verify before acting.** A fresh reader can misread an ambiguous glyph. If *two* independent cold readers misread the *same* symbol the same way, that is strong evidence the notation is genuinely ambiguous — change it even if it is "technically correct".
- **Genre, not perfection.** A plain-language report does not owe a formula for every descriptive quantity; an abstract may use a term it defines later. Distinguish real blockers (undefined load-bearing symbol, asserted load-bearing math, a metric never named) from style preferences.
- **Feed words back.** Any term the reader flags as jargon goes into the guard denylist (SKILL.md step 5).
- **Re-run after substantial fixes.** New derivations or notation changes can introduce new cold-read problems; the gate is cheap relative to shipping a doc a colleague cannot follow.
