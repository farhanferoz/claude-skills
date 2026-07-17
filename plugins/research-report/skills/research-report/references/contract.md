# Research-report genre contract

A *research report* — a shareable technical note that explains a model, a derivation, or
an experiment — is written as a **self-contained book chapter**: a reader with no access
to the codebase and no memory of this work can read it start to finish and follow every
step.

This is the report-specific layer. It sits **on top of** `notes/research/DOC_STANDARD.md`
(source-first, snapshot integrity, math-as-math, figures, tables) and adds the seven rules
below. It does not restate the base standard.

The acceptance test for every rule is a **cold read** by someone outside the project. The
author's own re-read does not count: the author's working context silently fills the gaps,
which is exactly how undefined terms and code references keep shipping. Rules 1, 2, 5 and
the figure half of rule 7 are checked mechanically (a grep guard); rules 3, 4, the
"computed-result is shown" half of rule 7, and anything merely cryptic, are checked by a
fresh-context cold-reader pass.

---

## The rules

### 1. No code references — write as if the codebase does not exist
No file paths, function names, class names, config keys, `.py`/`.yaml`, or CLI commands.
The reader cannot open the repository and must never be sent there. Describe **what the
thing does**, not **where it lives**.

- Before: "the covariance is evaluated in `src/autocast/losses/gaussian.py` via the
  Woodbury identity"
- After: "the covariance is evaluated using the Woodbury identity (defined below), which
  avoids ever forming the full N×N matrix"

### 2. Plain words — no coined or fancy terms
If an everyday word carries the meaning, use it. Do not invent labels, and do not reach
for a fancy synonym when a plain one exists. Where a technical term is genuinely standard
and unavoidable, define it in plain language at first use (rule 3).

- Before: "the amortised prediction head"; "the modes are algebraically slaved to the mean"
- After: "the prediction head, which shares one set of weights across all inputs"; "the
  modes are forced to track the mean — they cannot vary independently of it"
- Common offenders to replace: *amortised* → "shared"; *pricing* → "weighting";
  *surrogate* → "approximation"; *slaved/slavery* → "forced to track"; coined section
  titles → plain descriptions.

### 3. Every named object is defined where it is first used, with its formula
No symbol, identity, estimator, or method is referenced as if the reader already knows it.
Define it inline, at the point of use — not in a distant glossary, not by name only.

- Before: "evaluated through the Woodbury identity"
- After: "evaluated through the Woodbury identity — the rule that lets us rewrite
  $(A + UV^\top)^{-1}$ without ever inverting an N×N matrix [display the rewrite] — so the
  cost stays linear in N"
- Same for any acronym used as a concept: the point-estimate version (called MAP, the
  single most-likely value of the parameters rather than a distribution over them).

### 4. Load-bearing math is motivated and derived, not asserted
The central object the result rests on — the bound, the loss, the estimator — gets a full
derivation **and** an explanation of *why it is the right thing to optimise*. If the
derivation is long it goes in an appendix, but it must be there. A name plus a one-line
formula is not enough.

- Before: "Training maximises the evidence lower bound (ELBO), [formula]"
- After: one main-text sentence on what the bound buys us, plus an appendix that derives it
  from scratch — start from the quantity we actually want, show why it cannot be computed
  directly, introduce the approximating distribution, apply the standard inequality that
  lets us move the logarithm inside an average (Jensen's inequality), arrive at the bound,
  and say what each term means.

### 5. Math is typeset as math
Inherited from `DOC_STANDARD.md` §4b: formulas in LaTeX math, display math for anything
load-bearing, ASCII LaTeX inside `$...$`, never a formula inside a code span.

### 6. Cite real sources — only where they earn it
A result, method, or named identity that is **not original to this work** and that a reader
might want to follow up gets a citation. Citations are author–year, collected in a
**References** section at the end.
- **Verified, never recalled.** Every entry is a real work whose author, year, and venue
  were checked against the source *this session*. An invented or approximately-remembered
  citation is worse than none.
- **Only useful ones.** Cite where the pointer genuinely helps the reader — the
  load-bearing external results. Never cite for the sake of a reference list. A standard
  object the doc fully defines itself (e.g. a mean-reverting Gaussian process written out
  in full) needs no citation.

### 7. Completeness — show the evidence you have, in the form that carries it
Every computed result the conclusion rests on appears as a **table or figure**, not merely
summarised in prose; and every figure generated for the report is **embedded and explained**.
The failure this prevents: a run produces a grid, a per-category breakdown, and two plots,
and the write-up quotes one number from each in a sentence while the table and the figures
sit unused on disk — the reader is told the conclusion but never shown the evidence that a
peer could check or a chart that makes it legible.

- A result spanning a grid (parameters × outcomes), a breakdown across categories/years, or
  a sweep gets the **table**, not a prose paraphrase of its headline cell. Quote the headline
  in prose *and* show the grid.
- An idea worth discussing is worth a **figure** — a calibration curve, an equity path, a
  cost-vs-price curve, an economics bar — even when the idea was reasoned through rather than
  back-tested; label such an illustrative figure as showing the formula/economics, not a test.
- Declare the report's figure namespace in a manifest comment near the top so the guard can
  enforce coverage: `<!-- report-figures: kalshi-flb pm-cost pm-crossvenue -->`. Every PNG in
  the sibling `figures/` directory matching a listed prefix must be embedded, or the build fails.
- Keep an **artifact ledger** while finishing (the mirror of the claims ledger): list every
  results table and figure produced for the report and tick each as *surfaced* or *consciously
  excluded with a reason*. Nothing computed vanishes silently.

### 8. The acceptance test is a cold read
The report is done only when a reader with no project context and no code access can
follow it cold. Checked by: (a) the grep guard for rules 1, 2, 5 and figure coverage
(rule 7); (b) a fresh-context cold-reader pass for rules 3, 4, the "is the computed result
actually shown" half of rule 7, and anything cryptic. Whatever the cold reader flags as
unfamiliar feeds back into the guard's denylist, so the same word never ships twice.

---

## Formatting

Formatting is fixed once in a **shared build template** (a LaTeX header plus pandoc
settings bundled with this skill under `assets/`) that every report includes — not
hand-tuned per document — so good typography is automatic and future-proof, the same way
the hard guards are.

**Look: a polished book chapter.**
- A book serif (TeX Gyre Pagella or Libertinus), not bare Latin Modern.
- A narrow measure — roughly 65–75 characters per line (wider margins or a fixed text
  width), not the full 1-inch-margin width that currently runs ~95 characters.
- `microtype` on, to remove loose justification, rivers, and hyphen-break artifacts
  (e.g. "decision- making" split across a line).
- A deliberate heading hierarchy with controlled spacing.
- **No rules between sections** — drop the markdown `---` thematic breaks that render as
  stray centered rules.
- Indented paragraphs, no inter-paragraph gaps (classic book style).
- Single-line table cells (multiline cells clip silently at page breaks).

**Equations: separate the important ones.**
- A small expression — a single symbol or a short relation — may stay inline.
- Any **important or long** equation (a definition, a loss, a bound, an SDE, anything
  load-bearing) is set on its **own line as display math**, apart from the prose. When in
  doubt, display it. (This is the firm reading of DOC_STANDARD §4b.)

---

## How this is enforced (this skill)
1. A **grep guard** (`scripts/report_guard.sh`): hard-fail on code-reference signatures and
   on a growing **denylist** of banned words. Extends the base hard guards from the standard
   it layers on (section-0, bare `√`, math-in-backticks).
2. A **shared build template** (`assets/book_chapter.tex`) carrying the book-chapter
   typography above (font, measure, `microtype`, heading style, no section rules), applied by
   `scripts/build_report.sh` so formatting is set once, not per document. The build renders
   citations with pandoc's `--citeproc` from a verified bibliography (`assets/references.bib`,
   or a `references.bib` beside the document).
3. A **cold-reader pass** (`references/cold-reader-prompt.md`): a fresh subagent with no
   session context and no code access reads only the rendered **PDF** — never the markdown
   source, where citations and cross-references are still unresolved tokens — and lists every
   term it cannot define from the text alone and every passage it finds cryptic.
4. These run as a loop — draft, guard, build, cold-read, fix, repeat — until both gates are
   clean. Any word the cold reader flags as jargon is added to the guard's denylist so it
   can never ship again.
