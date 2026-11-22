# Cold-reader gate prompt

Spawn a **fresh subagent on Opus** (R3 — pinned, not the session default) with
the prompt below. Fill in `<ABSOLUTE_PDF_PATH>`, `<N>` (page count), and
`<ABSOLUTE_FINDINGS_PATH>` (the spawner picks this — conventionally
`<doc dir>/evidence/coldread_<n>.md`). The agent must read the rendered PDF,
never the markdown, and must WRITE its findings to the given file rather than
return them as its final message (R1): the subagent result channel truncates
a returned message at roughly 8.5 KB on first delivery and 4.1 KB on a
re-request, and a full cold read is routinely larger than that.

If the report is long, the reader should use the Read tool's `pages` parameter so it actually sees typeset math, figures, tables, and equation numbers.

---

You are a careful technical reader from OUTSIDE this project. You have NO prior context about this work and NO access to any codebase. Your ONLY source is one rendered PDF. Do not open, read, search, or infer from any other file, repository, or note — a real cold reader cannot do that.

Read this PDF start to finish, as a self-contained document:
`<ABSOLUTE_PDF_PATH>`

It is `<N>` pages. Use the Read tool with the `pages` parameter (e.g. pages "1-<N>", or in two requests) so you see the typeset math, figures, tables, and equation numbers — NOT markdown source.

This is a research report that must pass a strict "cold read": a reader with no project context and no code access must follow every step. Find where it fails. Be specific — quote the offending text with its section/appendix number and equation number.

Work through the categories below, then sort every finding into exactly two lists (R2):

- A **blocker** is: a colleague could not follow it; a number is wrong; a claim's evidence is not shown; or a page is unreadable.
- Everything else is **other** — real, worth fixing, but not what decides whether this document is ready.

Consider each category:

1. UNDEFINED TERMS / SYMBOLS — any term, symbol, acronym, estimator, matrix, or named identity used as if the reader already knows it, not defined in plain language at or before first use. Scrutinise every symbol in every equation: is it introduced? Watch for notation conventions left unstated (e.g. which parameterisation a distribution uses) and for one symbol reused with two meanings.

2. CRYPTIC OR UNFOLLOWABLE PASSAGES — any sentence, derivation step, or table cell you could not follow on one careful read: a logical jump, an unexplained "therefore", a number whose origin is not given, a table whose rows/columns you cannot interpret, an equation asserted rather than shown.

3. MATH NOT DERIVED OR MOTIVATED — any load-bearing formula (a bound, loss, update rule, estimator, key result) stated without either a derivation (possibly in an appendix) or a clear statement of why it is the right thing. For each central object, say explicitly whether a cold reader can follow its justification.

4. INCONSISTENCIES — any place two parts disagree: a number, a claim, a cross-reference pointing somewhere wrong, a symbol used two ways, a value rounded differently in different places.

5. ANYTHING ELSE that would trip a cold reader: jargon or coined labels used before definition, undefined cross-references, figures/tables not explained by the prose, a metric carrying numbers but never named/defined.

6. ORGANISATION — how the document is BUILT, not how its sentences read. This is a first-class category, not a style note; report it as forcefully as a wrong number. Specifically:
   - **Order.** Is anything load-bearing used well before it is explained? Name the term, the page it is first used on, and the page it is defined on.
   - **Proportion.** Do sections covering comparable things get comparable depth and comparable evidence? Name any subject given a fraction of the treatment its siblings get, and any single section that dominates the document.
   - **One job per heading.** Does any section carry two different kinds of material (conventions and results, or one subject's construction inside another subject's section)? Does any heading promise something different from what follows?
   - **Heading register.** Does any heading comment on the section ("in plain terms", "the honest reading", "what really happened") rather than naming its subject? Are the headings varied, or does one construction repeat until it stops distinguishing them?
   - **Captions.** Does any table caption run past one sentence, carrying caveats that belong in the prose?
   - **The shape overall.** After reading, state in one sentence what principle decides the section order — and say if you cannot tell.

7. UNDER-SHOWN EVIDENCE — prose that summarises or asserts data the reader is never shown. Flag any sentence that describes a grid, sweep, per-category/per-year breakdown, or multi-case result ("across the grid of N variants…", "broken out by category…", "every cell loses…") where no corresponding table appears; any headline number presented without the table it was drawn from; and any quantitative idea or strategy discussed with no figure to make it legible. You are judging only what the PDF shows — if a claim implies a table or chart that is absent, say so.

8. PRESENTATION AND LEGIBILITY — judge what you can actually SEE on the rendered page, not what the content says. This category exists because the contract requires single-line table cells (multiline cells clip silently at page breaks) and nothing else checks it.
   - **Tables.** Does any table wrap cells across lines, overflow the text width, or become unreadable? Does any column of numbers break mid-value? Name the table and the page. A table you have to decode rather than read is a defect, however correct its numbers.
   - **Figures.** Is any figure too small to read at printed size, too dense, or cramming panels into one row so that axis labels and tick text are illegible? Name the figure and the page.
   - **Figure text.** Does any figure carry labels, legends or titles in a vocabulary the prose does not use — internal names, abbreviations, or codes that appear nowhere in the text? A figure that names things differently from the report reads as being about different objects.
   - Does any caption promise something the image does not show?

If a section is clean, say so explicitly, but do not summarise the document back — only the problems, plus confirmation of what is now clean.

**Now write your findings to this file** (create it; overwrite if it exists):
`<ABSOLUTE_FINDINGS_PATH>`

Structure the file as exactly two sections, in this order:

```
## BLOCKERS

(at most 10, ranked worst-first — a colleague cannot follow it, a number is
wrong, a claim's evidence is not shown, or a page is unreadable. If there are
none, write "none.")

## OTHER

(everything else you found, flat, unranked — real but not blocking. If there
are none, write "none.")
```

Do not put more than 10 items in `## BLOCKERS`; if you found more than 10
blocker-grade issues, that is itself the top finding — say so at the top of
the section and list only the worst 10.

**Do not return the findings as your final message, and do not use
SendMessage.** Write the file, then reply with EXACTLY one line and nothing
else:

`written, <N> blockers, <M> other`

(R1 — the subagent result channel truncates a long final message before it
reaches whoever spawned you; a full cold read routinely exceeds that. Writing
to a file and replying with one line is what gets the findings through
intact. Measured 2026-08-12, separately: a cold reader completed a full
22-page read, then sent its findings via SendMessage to an invented recipient
name — the send reported success, the report reached nobody, and the whole
read was nearly lost. Do not use SendMessage for any part of this.)

---

## Triaging the report

- **Verify before acting.** A fresh reader can misread an ambiguous glyph. If *two* independent cold readers misread the *same* symbol the same way, that is strong evidence the notation is genuinely ambiguous — change it even if it is "technically correct".
- **Genre, not perfection.** A plain-language report does not owe a formula for every descriptive quantity; an abstract may use a term it defines later. Distinguish real blockers (undefined load-bearing symbol, asserted load-bearing math, a metric never named) from style preferences.
- **Organisation findings are NOT style preferences.** Category 6 is exempt from the line above, and the exemption is deliberate: a document can pass every per-sentence check and still be built wrong, and that failure is invisible to the author, who knows where everything is. Treat a wrong section order, a section carrying a quarter of the document, or a subject covered in a fraction of its siblings' depth as a blocker. If the reader reports it, fix the structure — never reword inside it.
- **Feed words back.** Any term the reader flags as jargon goes into the guard denylist (SKILL.md step 5).
- **Re-run after substantial fixes** — but two reads is the ceiling (R3). If a second read still returns blockers, that is a sign the document was not ready, not a reason for a third; go back to authoring (the definitions register, U2 section rewrite) rather than asking for another read.
