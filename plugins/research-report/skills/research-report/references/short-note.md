# Short-note mode

A **short note** is a two-to-six-page technical note for colleagues: one subject,
no numbered sections, read in a sitting. It is a **mode of this genre, not a
different genre** — every contract rule still binds, and the loop, the guard, the
render review and the cold read are unchanged. What changes is the shape of the
document and four rules that a chapter-length report can afford and a note cannot.

Build it with `--note` (10pt, no contents page). Everything below is a delta
against `contract.md`; where this page is silent, the contract governs.

The incidents behind every rule here are one session: `CHANGELOG.md`, 2026-09-10.

## The shape

**No numbered sections. Movements, not sections.** A note is a sequence of
paragraphs whose first phrase is set in bold — the *run-in lead* — carrying the
argument forward. Numbered headings over 300-word bodies turn a note into a short
chapter with a contents page missing.

**The run-in lead of every movement is a technical claim.** Not a rhetorical
framing, not an invitation, not a question the paragraph then answers. Cheap test:
if the lead contains a second-person pronoun, *people*, *what really*, or *the
trick*, it is framing and not a claim. Two that shipped and had to be rewritten:
*"The questions people ask of a forecast are not per-point questions"* and *"You
cannot fix what you cannot see"*. Owner, on both: *"It does not look technical. or
sound technical."*

**Order inside a construction is fixed: what is wanted, why the standard choices
fail and what they cost, then the construction.** Opening with the mechanism —
*"Flatten a frame on an n × n grid…"* — is the single most common way a note reads
as a manual. Motivate, then build.

## The four deltas

1. **Standard field terms are used undefined; the document's own objects are
   always defined.** Contract rule 2 asks for a definition of any standard term at
   first use, which is right for a report crossing fields and wrong for a note whose
   readers are colleagues. A note may write *covariance*, *ensemble*, *rollout*
   without ceremony. It may never leave its own metric, model or constant undefined
   — that half of rule 3 is not relaxed, and it is what the cold read enforces.
2. **Captions are one to three sentences.** A chapter's caption can carry a
   paragraph. A note's cannot: the caption competes with the body for the same page.
3. **The title is at most nine words and fits one typeset line**, and it names what
   is *done*, not the field it is done in. Check the rendered title box for wrap —
   a title that wraps is over budget whatever its word count. A shipped example:
   **"Predicting the covariance, not just the variance"**.
4. **The section list is a movement list.** Step 0b is not skipped — a note still
   declares its spine and writes `SECTION_LIST.md` — but the rows are movements with
   a word budget, and the manifest is `per-subject` unless the note genuinely
   stages an argument.

## What is not relaxed

**Nothing else.** In particular:

- **The pre-draft register is mandatory and matters more here, not less.** A note
  has room for three or four figures, so choosing the wrong one costs a larger
  fraction of the document. See `evidence.md`, "The pre-draft register".
- **Voice is findings, never user manual.** *"We evaluate under…"*, *"We therefore
  report the panel…"* — nine such constructions shipped in a four-page note and all
  nine had to go. Say what is true and what was found, not what the authors did with
  their afternoon. The guard counts these and prints the count.
- **Metric names are proper names with acronyms**, capitalised, verified against
  source rather than coined: **Spread–Skill Ratio (SSR)**, **Coverage Error (%)**,
  **Normalised RMSE (nRMSE)**. Not `spread ÷ error`.
- **Every named contribution is named in the movement that carries it.** A novelty
  paragraph that names neither the model nor the scheme it is about is the defect
  this rule exists for; the guard refuses it.
- **The cold read still gates**, and two reads is still the ceiling.

## Build notes for a note

- `--note` sets 10pt and drops the contents page. A note with `--toc` emits a bare
  *Contents* heading over an empty list.
- To override the chapter template — margins, title block — put a `preamble.tex`
  beside the document. ⛔ **Do not use YAML `header-includes` or a fenced
  `{=latex}` block: on pandoc 3.1.3 both are silently dropped**, with no error and
  no effect. Verified 2026-09-10 and re-verified at every preflight since; the
  preflight prints which route this pandoc honours.
- Let figures float (`htbp`). Pinning them with `[H]` packs the document worse, not
  better: on the 2026-09-10 note it left a 45%-empty page. The build prints a
  page-fill report so a sparse page shows up without opening the PDF.
- A table that breaks across a page is fixed with `\needspace{<n>\baselineskip}` on
  its own line above the table. Bare inline LaTeX on its own line *does* reach the
  document; the two routes above do not.
