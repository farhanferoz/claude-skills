# Report structure standard

The clarity gates in this skill (guard + cold read) check whether each *sentence* can be
followed. They say nothing about whether the *document* is built correctly. A report can
pass every one of them and still be badly organised: the wrong spine, one section carrying
a quarter of the content, parallel subjects covered at wildly different depth, headings
that editorialise, captions doing prose's job.

That failure has a signature. It happens when a document is **grown rather than authored** —
drafted once, then corrected many times, with each correction landing wherever the author
happened to be editing. Every individual correction is right; the shape is wrong; and no
per-sentence gate can see it, because no sentence is at fault.

This standard is the missing layer. Read it **before drafting** and re-read it before any
substantial revision.

---

## 1. Choose the spine before writing a word

A report's **spine** is the principle that decides what the sections are. Choosing it is
the single highest-leverage decision in the document, and it must be made explicitly and
first — never inherited by default.

Three spines cover almost everything:

**A. Per-subject** — one section per comparable thing (per strategy, per model, per
dataset, per candidate approach). Use when the report covers *N* things of the same kind.
This spine is self-enforcing: N things means N sections, and nothing can drift.

**B. Per-stage** — one section per step of a single pipeline or derivation. Use when the
report is about *one* thing built in stages, where each stage depends on the last.

**C. Compositional** — parts, then intermediate combinations, then the whole. Use when the
report is about **combining** things: individual components first, each fully described and
graded on its own; then each component as a standalone deliverable in every form it can
take (each wrapper, each variant); then the combined result; then what governs the
combination.

Spine C is the one most often missed, because a report about a combination has no natural
count of parts to force the issue. **A document about a combination that does not pick
spine C will silently default into report-paper shape** — introduction, method, results,
discussion — which buries every component's own story inside a methods section and
re-litigates the same cross-cutting question (which wrapper? which sizing? what does it
cost?) once per results section instead of once per component.

Write the spine down as a section list, and put it in the document as a manifest comment
so the guard can see it:

```
<!-- report-structure: compositional -->
```

Valid values: `per-subject`, `per-stage`, `compositional`. If none of the three fits, name
your own and say in one line what decides the sections — but be suspicious: the usual
reason none fits is that the spine has not actually been chosen.

## 2. Shared machinery goes up front, once

Anything every subject needs — how quantities are measured, how things are sized, what
counts as good, what costs are charged, which statistical test is used — goes in **one
early section**, before the subjects. It is stated once and referred back to.

The failure this prevents: conventions that get explained in the first subject that needs
them, so the reader meets a load-bearing term on page 2 and its definition on page 29; or,
worse, get explained three times with three slightly different emphases.

A cold reader flagging "term X is used long before it is defined" is usually reporting
*this* defect, not a missing definition. Fix the ordering, not the sentence.

## 3. Parallel subjects get comparable depth

If two sections cover things of the same kind, they get comparable treatment: the same
questions answered, the same kinds of evidence shown.

- No parallel subject section should be more than about **twice** the length of its
  siblings.
- Every subject section carries **at least one table and one figure**. A subject described
  only in prose has not been shown, it has been asserted (contract rule 7).
- If one subject genuinely deserves far more room, that is a signal it is not a sibling of
  the others — promote it, or split what it is carrying.

The usual cause of a large skew is recency: whichever subject was most recently corrected,
argued about, or fixed accumulates all the discussion, and the others keep their original
two paragraphs. Proportion should follow what the reader needs, never what the author
touched last.

## 4. One heading, one job

A section does one of: set conventions, describe a subject, present a result, argue a
decision, or state limits. A section doing two is two sections.

Warning signs that a section has more than one job:
- its title contains "and" joining two different kinds of thing ("the blend and the
  wrapper");
- it is more than about **three times** the median section length;
- it contains a construction detail belonging to a subject described elsewhere.

The size rule is mechanical and the guard enforces it, because an oversized section is the
most reliable visible symptom of a structural problem: corrections pile into whichever
section is nearest the topic, and the section that keeps growing is the one whose job was
never pinned down.

## 5. Headings name their subject

A heading is a label for the content, not a comment on it.

- **Name the subject**: "Financing cost of the levered book", "Marginal contribution of the
  credit sleeve", "The month-end overlay".
- **No register commentary**: not "in plain terms", "honest reading", "the headline
  result", "what actually happened", "how correlated they really are". These tell the
  reader how to feel about the section, imply the other sections are different, and read as
  defensive.
- **No rhetorical questions** as headings.
- **Use the colon-gloss sparingly.** "Subject: what it means" is fine once or twice; when
  most headings use it, it has become a tic and the headings stop distinguishing themselves.

## 6. Captions name; prose explains

**Table captions are one sentence** naming what the table shows. Nothing else. Caveats
about which construction produced the numbers, which window they cover, what they must not
be compared against, and what has not yet been re-measured go in the prose above the table
or in a footnote below it.

A caption that has grown to a paragraph is a symptom of the accretion failure: each
correction appended its qualifier to the caption because that was the safest place to put
it, and nobody ever read the result as a whole.

Figure captions may be longer — a figure travels separately from its prose and must stand
alone — but they still describe, they do not argue.

## 7. A correction may not change the shape

This is the rule that keeps a corrected document from becoming a badly-built one, and it
binds every revision pass, including a delegated one.

- A correction goes to **the section that owns the topic**, not the section you happened to
  be editing.
- If a correction needs more than a sentence or two, ask whether the section it lands in
  still has one job. If not, split before adding.
- If a correction would make a section the largest in the document, **stop and restructure
  first**.
- Corrections are not only additive. A superseded paragraph is deleted or rewritten, never
  left standing beside its replacement with a note explaining which one is current.

**When briefing someone else to revise a report, say this explicitly.** A brief that says
"bring this document onto the corrected numbers" licenses only additions — the reviser will
append caveats, daggers and qualifying sentences, because deleting or moving material is
outside what they were asked to do. Structure is then the one defect class the revision
pass mechanically cannot fix. Either put the structure in scope, or accept that the pass
will preserve whatever shape the document already has.

## 8. Revising an existing report

Before revising a report you did not just write:

1. Print the section budget — words, tables and figures per section. Skew and empty
   sections are visible in seconds and invisible on a read-through.
2. Check the spine is still the one declared in the manifest, and that it is still right.
3. Only then start editing.

If the budget shows a section over three times the median, or parallel subjects differing
by more than double, fix that before touching any wording. Rewording inside a broken shape
is wasted work — it will be rewritten again when the shape is fixed.
