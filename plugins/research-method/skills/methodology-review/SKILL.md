---
name: methodology-review
description: Use when asked to review, audit or critique the methodology of a research model or programme (problem set-up, model construction, toy or benchmark design, statistical rigour, next steps), to write terms of reference for such a review, or to act on its recommendations — above all when months of plans and code written by assistants sit between the owner's original intent and the work under review. Also use, unasked, before a data pipeline's first long run and after any redesign of one, for the four data pipeline checks.
---

# Methodology review

## Overview
A review tests the work against **the owner's intent**. The framing carried by the inputs — terms of
reference, plans, code defaults, earlier reviews — is itself under review: it is how drift gets in, and a
reviewer who takes it as given certifies the drift. Five gates below are not optional; the rest is
ordinary good reviewing.

**Violating the letter of a gate is violating its spirit.**

## The gates
1. **Intent sheet first.** The owner's own description of what the model is, what it is for, the
   yardstick, and what may not change — verbatim, dated, and confirmed by the owner for THIS review.
   Older owner writing (a README, an old plan) is evidence to quote, not the sheet. Missing? Ask. Never
   reconstruct it from plans, code or a previous review.
2. **Readback, then STOP.** One page (template: `terms_of_reference_template.md`, "Readback"): the model,
   the yardstick and the questions as you understand them, plus every place where an input (terms, plan,
   default, decision record) disagrees with the intent sheet. Reading inputs and already-recorded results
   to write it is allowed; judging, recommending and running are not. The owner confirms or corrects;
   nothing proceeds until they do.
3. **Identity guard.** Any recommendation that changes the model's definition, supervision, training loss
   or yardstick goes in its own section, "Changes to what the model is", one question each, stated in
   those words. Never mixed into ordinary recommendations; never accepted "provisionally".
4. **No runs before rulings.** Validation experiments are proposed with their outcomes stated in advance
   and launched only after the owner has ruled on the items they test. Pre-approval to "do initial work"
   does not cover runs on framing the owner has not confirmed.
5. **Written for one-at-a-time reading.** A one-page summary; then one page per decision; plain words,
   every term defined on first use; long evidence in an appendix.

## How to review (after gate 2)
- **Evidence before judgement.** First a neutral map — question, design, claims — and each claim linked to
  its evidence (file:line, run, table). Then judge.
- **Each concern:** location · observation · consequence for the claim · uncertainty · remedy; ranked
  critical / important / minor. Never claim a reproduction that was not run.
- **Rigour checklist:** REFORMS' eight sections (study design, reproducibility, data quality,
  preprocessing, modelling, data leakage, metrics and uncertainty, generalisability), with the leakage
  taxonomy of Kapoor & Narayanan (2023): stopping or tuning on the reporting set is leakage.
- **Score every arm on the owner's yardstick**, and on a metric it was not trained on.

Terms-of-reference template: `terms_of_reference_template.md` (this folder).

## Data pipeline checks (before a pipeline's first long run, and after any redesign)
Give the pipeline's code and its objective to an independent reader (a fresh agent with the code, not
your conclusions); it answers each check with file:line evidence. A failed check is fixed before the run.
1. **A cache key covers exactly what its work depends on.** Each saved result is keyed on the inputs
   and code that result reads: nothing global (a register appended nightly, a module's whole import
   closure), nothing missing (a stage marker without the code that makes the stage).
2. **Every step reports how much of its input it used.** Per step: records in, records kept, each drop
   with its reason, shown beside the result. A result built on a small share of the data says so on the
   first run.
3. **A general mechanism is first run on the most different case** (the case least like the one it was
   built on), before it is called general. Name what makes that case hard and measure it in both cases:
   a pass on a case that lacks the stressor is not evidence.
4. **A ruling is enforced by a test.** Every owner ruling a parameter encodes has a test that fails while
   code reads the superseded value; a ruling marked "not yet built" blocks the result it governs.

Why (sports latency study, 2026-11-07): saved work keyed on a register that grew every night was
remade daily; one sport's results used about 3% of its events and no page said so; a mechanism built on
hockey broke on Formula 1 weeks later; an overruled 10-game minimum ran for 17 days. And (ARFC, 2026-11-20) a covariance change passed on
toys whose windows vary 3.8 and 2.0 nats in one-step change, then failed on a system whose windows vary
7.4; a toy that varied 10.7 existed and was not used. Training changes have their own pre-run checks:
the `training-change-checks` skill.

## Rationalisations — and the answer
| Thought | Reality |
|---|---|
| "Runs tonight are provisional and reversible" | Runs on unconfirmed framing cost days and anchor the owner on wrong numbers. Gate 4. |
| "The terms of reference fix it" | The terms are an input under review. Check them against the intent sheet. |
| "The owner pre-approved initial work" | Not for framing they have not confirmed. Gates 2 and 4. |
| "I'll flag the question and carry on meanwhile" | The readback is a stop, not a note. |
| "Changing the supervision is just one recommendation among many" | It changes what the model is. Gate 3. |
| "The plan has been this way for months" | Assistant-written plans are where drift lives. |

## Red flags — stop
- Starting the review without the owner's verbatim intent
- A recommendation that changes the loss, supervision or yardstick, outside its own section
- Launching any experiment before the owner has ruled
- A data pipeline's first long run, or its run after a redesign, without the four pipeline checks
- A deliverable the owner cannot read one decision at a time

Credits: evidence-first appraisal and the concern format adapted from K-Dense scientific-agent-skills
(`scientific-critical-thinking`, `peer-review`; MIT). Checklist: REFORMS (reforms.cs.princeton.edu).
