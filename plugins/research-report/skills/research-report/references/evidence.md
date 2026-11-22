# Evidence — assembling it before you draft

The contract's completeness rule says *show the evidence you have*. This page is about
making sure you have it, and that it is still true, before the first sentence is written.

The failure this prevents is not a writing failure. It is a report that reads beautifully,
passes the guard, passes the cold read, and rests on a number that was retracted a month
ago in a document nobody re-opened. No per-sentence check can catch that, because every
sentence is fine.

## The rule

**Freeze the evidence, then write.** Drafting and investigating are different activities,
and doing them at once produces the worst of both: prose written around whatever was
convenient to look up, and lookups shaped by the sentence already half-written.

By the time you draft, every number in the report should be traceable to a row in a
register you assembled deliberately. Writing then becomes writing.

## The pre-draft register (`evidence/predraft.md`)

Before the three artifacts below, and before the first sentence, four decisions get
written down. They are two minutes of work and they are the ones that cost most when
they are made late: on 2026-09-10 a four-page note took roughly a dozen review rounds,
four of them full rewrites, and **almost none of it was a writing failure**. It was
this file, missing.

`scripts/predraft_gate.sh <report-dir>` checks it before you draft; the guard runs the
same checker on the draft, so it cannot be skipped by starting to write.

### 1. The subject, in one sentence

What the document is *about* — not what it contains. The 2026-09-10 note was drafted as
a monograph on one model when the subject was a capability, with that model as one
contribution to it. Owner: *"this sounds like a report totally focused on [the model].
The report should be on [the capability] … with [the model] being one of the solutions."*

**The section list is not a substitute for this, and agreeing it first is what went
wrong.** The list had been agreed — against the wrong subject, so it agreed to the wrong
document. Subject first, then the list.

⚠ It is easy to seed the mis-framing yourself. That session's came from my own question
two turns earlier: I asked whether to emphasise novelty and read the answer as "make the
document about the novel thing".

### 2. Each contribution's role in that subject, in one sentence

One row per named contribution: what it is, what it contributes, and which section
carries it. The role sentence is what stops a contribution becoming the subject.

The `carried in` column is load-bearing: the guard refuses a document whose novelty
section never names the thing it is about. That happened — the paragraph carrying the
key innovation named neither the model nor the scheme, and the model appeared once in
the whole section describing it.

### 3. The asset inventory — every figure that already exists

Enumerate every figure in the source reports and every curve file in the data, **with
its point count**, before drawing anything. This is `ls`-level work and it is the item
with the highest measured return in this skill: a regional-coverage figure was built
from scratch with **2 points per curve** while the same repository held the same
measurement at **4** and at **7**, and a 20-level curve was sitting in the data.
Owner: *"fig not good enough. It only shows two points per curve. We have better
regional coverage plots."*

The point count is the column the guard demands, because it is the comparison that
decides reuse-or-redraw. A search that finds nothing is a result: record it as
`searched: <where> — none found`.

### 4. The contact sheet, whenever a figure is *selected* from a set

Six candidate case figures existed; they were proposed one at a time, refused one at a
time, for four rounds, and the owner eventually chose one from a directory they had
never been shown. **Show every candidate on one sheet and let whoever owns the report
choose.** Never propose one at a time. If nothing in this document is selected from a
set, say so in that heading, in those words.

### 5. Figure provenance, once figures exist

Any figure not drawn by a script in the report's own directory is declared here, saying
where it came from and that its **embedded text was inspected**. Internal codes reached
a built PDF twice in one session *inside images*, where no search over the markdown can
see them. Better than declaring: redraw a borrowed figure from its source values.

## The three artifacts

Scale each to the report. For a three-page note these are a single page of notes and ten
minutes. For a long project they are real work with their own budget — and worth it, because
the alternative is discovering the problem in the middle of a paragraph.

### 1. The claims register

Every number that could appear in the report, one row each:

| id | the claim, stated in one sentence with its number | uncertainty, if it has one | where it came from | when it was established |

Rules that earn their keep:

- **Do not silently pick.** If a number appears in two places with different values, record
  both and flag it. The person assembling the register is rarely the right person to
  resolve a conflict; whoever owns the report is.
- **Mark thin evidence in the row itself**, not in a footnote somewhere else. A result from
  a single run, a single seed, a single configuration should say so where it is quoted.
- **Record the margin or say there isn't one.** Never compute a fresh uncertainty while
  assembling — that is new analysis wearing a clerical disguise.

### 2. The supersession ledger

Every number, claim, or conclusion that has been *retired*, and what replaced it:

| what was retired | what replaced it | when | why | which documents still contain the stale version |

That last column is the one that matters. Corrections usually land in a changelog or a
newer document while the original sits untouched, still reading as authoritative. The
ledger is what stops a stale figure entering the report by being copied out of a document
that still contains it.

Things worth sweeping for: correction banners, "superseded", "withdrawn", "deleted",
"must not be quoted", "revised", and any figure a later result overturned. Also sweep for
*changed baselines* — when a reference value moves, every gap measured against the old one
is wrong by the difference, and every significance count with it, while the raw
measurements stay perfectly valid. Differences between two measurements are usually
unaffected; absolute distances from a reference are not.

A clean sweep is a useful result. Record what you swept and what you found, including
nothing.

### 3. The definitions register (`evidence/definitions.md`)

One heading per named object the document will use: every metric (its
formula, its direction, what it averages over), every model (architecture,
parameter count, training objective, the one hyperparameter that defines it),
every constant of the substrate or dataset, and the arm/setting/checkpoint
each table reports. Built from source, not from what the draft happens to
say — this is the register step 0a's definition sweep checks the document
against.

**The guard checks this mechanically (R4), by name only.** Every column
header of every markdown table that names a metric or score must have a
matching heading in `evidence/definitions.md` — case-insensitively, ignoring
units or suffixes in parentheses (`RMSE` and `RMSE (m)` match the same
heading). A table column with no matching heading refuses the build, listing
the missing names; a document with no tables skips the check with a note
rather than a refusal. This confirms a definition *exists*, nothing more —
whether it is *correct* is still the cold reader's job, same as everywhere
else the guard checks a name rather than content.

### 4. The figure inventory

Every figure the report will carry, and what it needs:

| id | which section | what it shows | what data it needs | where that data is | is it available right now |

The point of this one is timing. The contract expects figures to exist and be explained;
discovering during drafting that a plot requires a computation that has not happened stalls
the writing and tempts a prose paraphrase instead — which is precisely what rule 7 forbids.

Two things to check while you are in there:

- **Is the underlying data durable?** Evidence living in ignored or temporary directories is
  one deletion away from unrecoverable. Copy what the report depends on into the report's
  own directory. A report whose evidence has evaporated cannot be defended later.
- **Is a reused figure still current?** A plot generated for an earlier stage may encode an
  older configuration. Reusing it silently imports assumptions that have since changed.

## If you delegate the assembly

Worth doing when the material is large and separable — different bodies of evidence can be
read in parallel. Some things that make it work:

- **Give each worker exactly one file to write.** Two workers editing one artifact produce
  contradictions, not collaboration. Findings come back; the shared artifacts are written
  by whoever owns the report.
- **Tell them to write findings down as they verify them**, not at the end.
- **Tell them to flag conflicts rather than resolve them**, and to label anything they could
  not verify rather than filling the gap with something plausible.
- **Verify the load-bearing returns yourself against the source.** A worker's report is a
  claim, not a result — particularly for derivations, which are easy to assert and easy to
  get subtly wrong.

## Never state a difference without the scale that makes it meaningful

A number's decimal places are not evidence. A difference is a finding only relative to how
much the quantity moves for reasons you are not claiming — and that scale is almost always
knowable, so quoting a difference without it is a choice, not a limitation.

**Every difference the report states carries one of these, named:**

- the uncertainty **on the difference itself** — not on its endpoints. Two cells each with an
  error bar of 0.016 can differ by far less than 0.016 with high confidence if they are
  measured on the same data, and far more loosely if they are not. Quoting an endpoint's
  error bar against a difference is a category error, and an easy one to make because the
  endpoint's bar is the one printed.
- the **seed-to-seed spread**, where the thing varies by seed;
- the **run-to-run wander** of the quantity when nothing is changing — the noise floor.

**If none exists, say so explicitly and describe the difference as unquantified.** Do not
substitute the reader's intuition about decimal places for a scale you did not measure.

**A difference below its noise scale is reported as "no measurable difference"**, never as a
small effect, and never with an interpretation attached. The phrasing matters: "improves
slightly" and "is indistinguishable" describe the same data and mislead in opposite
directions.

The failure this prevents is subtle because it does not look like a mistake. A curve whose
last stretch varies in the fourth decimal place while its total range lives in the first is
*flat*, and an argument built on where its minimum falls is an argument about noise. Compute
what fraction of the total effect a stretch carries before describing that stretch at all —
if it is a few percent, that is the finding, and the location of the minimum inside it is not.

It is not permission to keep researching while writing. It exists so that the drafting step
reads from a frozen register instead of from recall.

It is also not a substitute for the cold read. Having assembled the evidence yourself makes
you the *most* contaminated possible reader of the result, not the least — you now know
what every sentence was supposed to say. The fresh-reader gate matters more after thorough
preparation, not less.
