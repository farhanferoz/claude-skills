---
name: training-change-checks
description: Use before a change to how a model trains gets its first long training run — a new or changed loss, parameterisation (a multiplier, scale head, reparameterised variance), normaliser or centring, bound or clamp, optimiser or schedule — and before building a second fix for a training failure. Also use when choosing a toy or benchmark to validate such a change. Checks the update training actually applies, each building block's dynamics, and a short stress run on the hardest real cases, in minutes, before hours of training.
---

# Training change checks

## Overview
A change to how a model trains meets its hardest case in minutes before it gets hours. A long run that
fails costs hours and reports only that it failed; these checks say why, before the run. A long run is
never a change's first test.

## The checks (before the first long run; a failed check is fixed first)
1. **Measure the update, not the objective.** Training follows the gradient of the training loss through
   everything between the network's output and the loss as it runs in training mode: batch statistics
   with their gradient, running averages, clamps and soft bounds, stop-gradients, train/eval branches,
   sampled sub-objectives (dropout, random truncations). Read that gradient where the change matters
   most: add a zero leaf offset at the quantity in question, read d(training loss)/d(offset) per
   example and per loss term, in training mode and in evaluation mode. Report it as a push (minus the
   gradient; positive = gradient descent raises the quantity). A probe of the evaluation-mode score can
   point the other way.
2. **Test each building block's dynamics, not only its values.** For every normaliser, centring, bound
   or reparameterisation, a permanent unit test on synthetic inputs checks how it MOVES: under a pull
   every element shares, under uneven pulls, and with some elements in a bound's flat region. Property:
   no element is pushed against its own pull; a shared pull moves only whatever owns the shared level.
   Worked failure: centre over the batch with the gradient, then soft-cap. With g_i the loss gradient at
   element i after the cap and s_i the cap's slope there, the raw gradient is s_i g_i - mean_j(s_j g_j).
   A shared pull g becomes g (s_i - mean s): the elements highest on the cap (smallest s_i) are pushed
   away from the centre, which flattens s_i further, a positive feedback. Capping before centring gives
   s_i (g_i - mean g): a shared pull cancels. The same failure read as a constraint: a constraint (zero
   mean, unit length, a fixed sum) holds only where it is imposed, so impose and test it on the values the
   model actually uses, after every later transformation (zero mean before the cap is not zero mean after it).
3. **Stress before length.** From a real checkpoint, a few hundred updates with the hardest cases shown
   more often, check 1 repeated every N updates beside the run's own health gauges. The long run starts
   only when the stress run is flat.
4. **A toy proves nothing about a stressor it lacks.** Name what makes the real case hard, measure it in
   the real data and in the toy, and count a toy pass only if the toy carries it at a comparable size.
   Otherwise stress on the real case's hardest examples (check 3).
5. **Two failed fixes for one symptom: stop.** Before a third, list what the failing parts share (a
   function every part passes through, a common element of the training path) and probe that.

## After a failure is diagnosed
1. The failing case becomes a permanent test built from the failure's own numbers, red on the old code.
2. Its general rule goes into the check above that should have caught it; if none would have, add a check.
3. Search the code for the same construction elsewhere and fix it there too, or record why not.
4. Record the ruling where the project records rulings (DECISIONS.md).

## Red flags — stop
- "The fix test will tell us" as the first test of a mechanism
- A mechanism argued from the objective (the score, the likelihood) with no reading of the update
- A toy pass cited for a case whose stressor the toy lacks
- A third fix for the same symptom

## Why (a research project, 20 Nov 2026)
Three multiplier problems in a row (the amplitude, then the pattern sizes, then a new per-point scale)
were each answered by a fix tested with a training run of 45 minutes to 7 hours; each fix failed or moved
the problem. The probes that explained them took one to two minutes each. The last fix added a per-point
scale to own the noise of one very noisy training trajectory; its pattern sizes still ran to the guard in
10 epochs. A score probe said every truncation level wanted those sizes lower. The training-gradient
probe showed why they rose: batch centring with its gradient, followed by an arctan cap (check 2's worked
failure), turned a pull every window shared into an upward push on the windows already highest on the
cap; the share of the pull reaching each window matched the cap's slope window by window (0.28 at
z = 11.5). That construction sat under every multiplier from the day it was built. The toys the change
was checked on vary 3.8 and 2.0 nats in one-step change across windows against the failing system's 7.4;
a toy that carried the stressor (10.7) existed and was not used. Evidence: a research project's notes
`notes/design/rank_ladder/arfc_paper_runs/multiplier_drift/read_multiplier_drift.md`; DECISIONS D394, D396.
