---
name: programme-plan
description: >-
  Structure and maintain the plan for a LONG, MULTI-STRAND programme — several
  parallel workstreams running for weeks or months. Use when starting such a
  programme, when an existing plan has drifted from reality, when plan files have
  multiplied and nobody can say "what do we do next", or when asked to reorganise a
  planning mess. NOT for a single multi-step task — use writing-plans.

---

# Programme plan — a plan that survives months and many writers

`writing-plans` covers a plan written once and executed once. This covers the other
thing: a plan that **lives**, across many strands, while the ground moves under it.

## The one idea

**A plan is a CACHE of disk state. Caches go stale.** Every planning failure in a long
programme is cache incoherence:

| Symptom | What it really is |
|---|---|
| "Plan says open, disk says done" | stale entry → work re-run for nothing |
| "Plan says 1.37, the ledger says 1.35" | stale copy of a number that moved |
| "Plan cites `foo.py:277`, it isn't there" | a cached pointer that rotted (or was never real) |

So the whole discipline is cache discipline: **cache less · check mechanically ·
invalidate in the same turn**.

## The structure

```
plan/
  MASTER.md          <- index + rules ONLY. No per-strand detail. Ever.
  <strand-a>.md      <- that strand's work items, evidence on every DONE row
  <strand-b>.md
  shared/<x>.md      <- work that gates MULTIPLE strands
  archive/           <- superseded plans. Kept, committed, NEVER dispatched from.
```

Read **MASTER + the ONE strand file you are working**. That is the whole context.

**MASTER carries:** a naming key (if names collide), the rules, the decision register
("settled, do not re-ask"), the strand index, the priority order, and a corrections
list. **The test before adding a line: "would someone working a *different* strand need
this?" If no → it belongs in the strand file.** Bloat is how the last plan died, and it
grows one reasonable-looking paragraph at a time.

## The rules that carry their weight

1. 🚫 **NEVER CREATE A DATED PLAN FILE.** No `PLAN_2026-01-05.md`. **The date in a
   filename is what licenses abandoning a plan instead of fixing it** — you get five
   competing plans, each written because the last couldn't be trusted, each then going
   stale too. A dated *findings note* is fine. A dated **plan** is the disease. If the
   plan is wrong, **fix it in place**. **Ship it as a test** (glob the plan dir, fail on
   a date-shaped filename, exempt `archive/`) — otherwise it is prose like everything else.
   *(This line previously called the rule "mechanical". It wasn't: no test enforced it for
   the first day of its life. A skill that claims a gate it never shipped is the very
   disease it is warning about — caught 2026-07-15 by grepping for the test and finding
   that the "hits" were `vali-dated` matching `dated`.)*
2. **One source of truth for numbers** (a ledger / results file), cited to a frozen
   artifact. **The plan holds POINTERS, not copies.** Every number copied into the plan
   is a cache entry that will rot. **A number that exists only as prose is not a result.**
3. **DONE only with EVIDENCE ATTACHED** — an artifact path or a ledger line. Not a
   status field, not a memory, not a worker's claim.
4. **Update the plan in the SAME TURN the work lands.** Deferred = stale. This is the
   single highest-frequency failure: plans get written while workers are still landing
   work, and are wrong within the hour.
5. 🚫 **Never cite a `file:line`, path, or verification command you have not opened.**
   Zero-context executors cannot tell a real citation from an invented one. **A guessed
   citation is assembled from real fragments and looks perfect** — a real line number
   from one file welded to a real filename from another. **A fabricated verification
   command is worse than none:** it sends the executor hunting a ghost.
6. **Verify a task is OPEN before dispatching it** — open the artifact, grep the symbol.
   If disk says done, mark it done with evidence and move on.
7. **Archive, don't delete.** Superseded plans hold reasoning worth keeping. Commit them
   somewhere they can never be dispatched from.

## Every task carries all five, or it is NOT dispatchable

exact files/paths · decision-complete spec · applicable doctrine · **the verification
command that reproduces a frozen number FIRST** · explicit non-goals.
Missing one → mark it **NOT-DISPATCHABLE** with the reason. Do not improvise the gap.

A dispatchable strand item also carries the same **Orchestration** line as a
writing-plans task (`parallel · deps · tier · scale · shape · verify` — see
writing-plans "Orchestration Tags"), and its files list is its WRITE SET: the
executor partitions dispatch waves from deps + write-set overlap, and a fully
execution-level strand can be compiled to a deterministic Workflow
(executing-plans/workflow-compile.md) instead of trusting dispatcher discipline.

⚠️ **The frozen number must itself have been verified INDEPENDENTLY — or the ritual runs
backwards.** Handing a worker "reproduce exactly: 32774" when that figure came from your own
unchecked one-liner does not verify the worker; it **conscripts the worker into confirming
your bug**, and returns it stamped *verified*. Exactly this happened (2026-07-15): the anchor
was a naive row-sum, inflated **225%**, the worker matched it perfectly, and the tool shipped
double-counting by 2–3×. It was caught only by an **independent** cross-check — a second tool
said the *part* ($147.87) exceeded the *whole* ($99.38), which is arithmetically impossible.
⇒ **Anchor on something you did not compute the same way** (a second implementation, an
invariant, a published total). An anchor derived from the method under test launders a guess
into a fact — the failure this whole discipline exists to prevent.

## Ship the gates, or the rules are decoration

**This is the condition, not a nice-to-have.** Prose rules get violated by the people who
just wrote them — reliably, within the hour. The only guards that hold are mechanical.
Ship them as **tests**; a script nobody runs is prose with a shebang.

**Two gates, because the plan caches two things that rot — pointers and numbers:**

| Gate | Catches | Reference implementation |
|---|---|---|
| **Citations** | a cited path/`file:line` that doesn't resolve | `~/dev/<project>/tests/test_plan_citations.py` |
| **Numbers** | a result-number in the plan that the ledger doesn't have | `~/dev/<project>/tests/test_plan_numbers.py` |

**The numbers gate matters more, and is the one people skip.** Every expensive error in the
source programme was a stale *number*, not a stale path — a headline `1.37` when the ledger
said `1.35`; a `1.339` "close call" put to the user three times when the ledger said `1.086`
and *underperforms*. The citation gate cannot see any of that: the path resolves fine.

Design notes that make a gate usable rather than ignored:
- **Only refs containing `/` are hard failures.** Bare filenames warn — too ambiguous.
- **Skip artifacts on network/remote roots** so it passes on any machine.
- **Exempt `archive/`** — frozen history is *allowed* to rot; failing on it creates
  pressure to edit the record.
- **An ignore marker** (`citecheck-ignore`, `numcheck-ignore`) so the plan can quote a bad
  citation, or a deliberate "was, pre-fix" number, as a worked example without tripping
  its own gate.
- 🔑 **Existing debt goes in a SHRINK-ONLY BASELINE, never a red suite.** Turning a gate on
  mid-programme surfaces real debt (32 orphan numbers, in the source case). **A permanently
  red suite gets ignored, which wastes the gate entirely.** So: list today's violations in
  a baseline file, fail on anything *not* in it, and fail if the baseline *grows*. New
  staleness is blocked immediately; old debt burns down on its own schedule. This one
  design choice is the difference between a gate that lives and a gate that gets `-x`'d.
- **Prove it fails.** Inject the bad citation / a stale number, watch it fire, revert. Prove
  the baseline can't grow, too. **A gate that has never failed is decoration.**
- **Check that your check runs.** A gate wired into nothing is prose. In the source case the
  per-turn policy hook was registered in only *half* the projects it claimed to govern, and
  nobody noticed because nothing recorded whether it fired. Grep for the enforcement, don't
  trust the doc that says it exists — including this one.
- 🔑 **KNOW WHAT YOUR GATE CANNOT SEE: the numbers gate proves EXISTENCE, not CURRENCY.** It asks
  "is this number in the ledger?" — and a **superseded** number is still in the ledger. In the
  source case the plan told the user a strategy *"underperforms, 1.086/1.488"* while the ledger's
  own later re-run said **1.339/1.790 — a tie and a post-24 win**. Both figures were real; they
  were computed on different **cost bases** (modelled vs measured, 3–11× apart). **The gate passed
  the entire time**, and the wrong number was repeated to the user *as a correction*. ⇒ **"The
  ledger says X" is not a citation.** A number needs its **basis** and its **line**, and the newest
  entry only wins if someone went looking for a newer one. A green gate is a floor, never a
  clean bill.

## Many agents on one plan

**Independence = disjoint WRITE sets, not different topics.** N agents on N strands all
writing one ledger are **N writers on one file**, and they will produce exactly the
incoherence above. **Fan out on compute; serialise on writes.** Workers return findings;
**the orchestrator writes the plan and the ledger** — that also forces a verification step
in front of every number that lands. See `~/.claude/CLAUDE.md` §Orchestration for the
full agent rules (lifecycle, incremental landing, no task-list browsing).

## Who orchestrates

**Orchestrate on the strong model; execute on the cheap one.** The orchestrator's real job
is *refusing to believe the plan* — and a cheaper tier is systematically worse at
distrusting fluent prose that happens to be wrong. Execution inside an already-verified
contract is where the cheap tier is genuinely sufficient, and where most of the volume is.

## Provenance

Extracted 2026-07-15 from a real recovery: five competing dated plans (66 files, ~12,767
lines, no answer to "what next"), 11 orphaned agents (measured: 273.4M billed tokens,
$63.23 — 99% of it cache *reads*, re-charged every turn, which is why a merely-alive agent
is expensive), a headline lever that was a measurement artifact, a "not started" workstream
that was already built and graded negative, and two fabricated citations.

**Revised the same day, by auditing this file against disk** — which is the only reason its
worst line got caught. Three of its own claims were wrong: it called the dated-file rule
"mechanical" when no test existed; it shipped only the citation gate while the *numbers*
were what actually cost money; and its "reproduce a frozen number first" rule had no warning
that an unverified anchor conscripts the worker into confirming your bug. **Every one was
fluent, plausible, and false — written by someone who had just spent a day cataloguing
exactly that failure.** That is the strongest argument in here for gates over rules, and it
is evidence against trusting this document any further than you can grep it.

**Generalised from ONE programme** — the structure and the cache framing should transfer;
treat the specifics as illustration, not law, until a second programme confirms them.
