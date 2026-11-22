# Owner presentation rules

A ruling made during a review round — "captions go below the table", "counts belong in
the appendix" — used to live only in the conversation where it was said. Nothing carried
it forward: the next draft, or the next person merging a revision, had no way to know the
decision had been made, and re-violated it. The skill already solves exactly this problem
for jargon — a word the cold reader flags goes into the guard's denylist (`references/contract.md`
rule 2, enforced by the `DENY` list in `scripts/report_guard.sh`) and can never ship again.
This file generalises that pattern to presentation rulings no grep pattern can express —
which family of rows comes first in a table, which statistic a figure is drawn on — by
keeping them as a durable register instead of letting them evaporate at the end of the call
that decided them.

Read at skill step 0, alongside the contract and the structure standard, before drafting or
revising.

## The rulings

Each entry is a rule this project's owner has made, dated, with the reason where one was
given. A ruling recorded without a reason is left that way — inventing one after the fact
would misrepresent the ruling as more considered than it was.

Made 2026-08-12:

1. **Captions are short naming phrases, never commentary, and sit below the object** —
   table or figure. Figure captions already rendered below, by pandoc's default; table
   captions did not — pandoc places a table's caption above the table, inside the table
   environment, so the document read with two different conventions depending on which kind
   of object was on the page. Mechanised the same day: a pandoc filter (`caption_below.lua`)
   strips the caption off the table and re-emits it immediately after, so tables now match
   figures.
2. **Table column headers are capitalised full words**, not lowercase codes or
   abbreviations carried over from whatever produced the numbers. Scope check, because it
   matters: this ruling was made immediately after a round of table and figure rebuilding
   and was implemented that day as table headers, so it is recorded here as a rule about
   table headers. It is NOT a ruling that document headings must be title case; the
   separate complaint that "most headings are terrible" was about headings naming their
   subject badly, which the guard's heading-register rule and the structure standard
   already cover.
3. **In results tables and heatmaps, marginal measurements come first as a group, then
   dependence-aware ones.** The two families are never interleaved row-by-row or
   column-by-column.
4. **Within those groups, variants of the same score sit adjacent** — every CRPS variant
   together, every coverage variant together — rather than ordered by model, dataset, or
   the sequence they happened to be computed in.
5. **Counts belong in the appendix, not in body results tables.** A results table reports
   the measurement; how many runs, seeds, or samples it is built from is supporting
   material for a reader who wants to check it, not part of the result itself.
6. **Where a table reports means, any figure drawn on medians must say so, and vice
   versa — state which statistic every displayed number is.** A reader comparing a table's
   mean against a figure's median without being told is comparing two different quantities
   as if they were one.
7. **Every displayed difference must carry its noise scale.** This is the same rule
   `references/evidence.md` already states for prose ("never state a difference without the
   scale that makes it meaningful"), applied to every difference that appears in a table or
   a figure, not only ones argued in the text.

## How this file grows

Every ruling made in a review round is added here in the same turn it is made — not
batched, not left for the next session to reconstruct from a chat transcript. Where a
ruling can be expressed mechanically, it also becomes a guard rule or a template change,
and that is the preferred form: rule 1's caption placement is no longer only a line in this
file, it is a pandoc filter that makes the violation impossible to ship. This file is for
what is left over — rulings like a table's row ordering or which statistic a figure shows,
that no grep pattern or build filter can check, and that would otherwise be enforced only
by someone remembering the call where they were decided.
