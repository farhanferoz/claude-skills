# Terms of reference — <model / programme> methodology review (<date>)

## 1. Purpose
An independent assessment of <model>'s methodology, ending in a verdict on what holds and a concrete,
testable programme of next steps. The owner's questions, in their words: <quote>.

## 2. Intent sheet — BINDING (the owner's words, verbatim, dated)
- **What the model is:** <owner's description>
- **What it is for / what success means:** <owner's words>
- **Yardstick:** <metric, data split, direction>
- **What may not change without a separate ruling:** <definition, supervision, loss, yardstick, ...>
- **Rulings in force:** <list with dates; anything not here is an input under review, not a given>

## 3. Gates (from the methodology-review skill — not optional)
1. Readback before any review work: one page — the model, yardstick and questions as you understand them,
   and every disagreement between an input and §2. Then stop until the owner confirms.
2. Changes to what the model is (definition, supervision, training loss, yardstick) go only in the
   deliverable's own section, one question each.
3. No validation runs until the owner has ruled on the items they test; propose them with outcomes
   stated in advance.

## 4. Inputs — facts to check, not framing to adopt
- Plans and decision records: <paths>. Written partly by assistants; test each against §2.
- Groundwork fact sheets: <paths>, regenerated on <date> against commit <hash>; spot-check ~5 rows each.
- Code: <paths>. Defaults are inputs too.

## 5. What the review must answer
1. Is the problem set up correctly — against §2?
2. Are the models built correctly (does the code do what §2 says)?
3. Are the toy problems / benchmarks right for the yardstick?
4. Is it statistically rigorous (REFORMS sections; leakage; seeds and intervals; multiplicity)?
5. What is missing (baselines on the yardstick, ablations, real data)?
6. What was done right and wrong?
7. Verdict and next steps: a programme of cards, each with question, arms, yardstick, seeds, cost,
   outcomes stated in advance.

## 6. How you work
Evidence before judgement (neutral map, claim → evidence); each concern as location · observation ·
consequence · uncertainty · remedy, ranked critical / important / minor; verify every external fact;
never claim a run you did not do.

## 7. Deliverable
- One-page summary for the owner.
- One page per decision: the question, the evidence, the options, your recommendation.
- Section "Changes to what the model is" (empty unless one is necessary).
- Proposed validation cards (not run).
- Appendix: evidence tables, what you did not read or could not verify.
Plain words; every term defined on first use.

## 8. Reading list
<ordered list with absolute paths>

---

# Readback (the reviewer's first deliverable — one page, then stop)

1. **The model, as I understand it** (3–5 sentences, plain words).
2. **The yardstick** (metric, data split, direction) and what it is compared against.
3. **The questions I will answer** (from §5, in my words).
4. **Where the inputs disagree with the intent sheet** — one line each: input (file:line) · what it says ·
   what the intent sheet says.
5. **What I need from you before I start** — numbered questions, each answerable in a word or a line.
