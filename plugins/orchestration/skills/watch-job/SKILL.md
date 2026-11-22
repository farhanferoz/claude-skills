---
name: watch-job
description: Use when asked to monitor, watch, wait on, babysit, or "tell me when it's done" for a long-running job, process, training run, build, test suite, deploy, or shell command — including overnight job-watching and "let me know when X finishes".
---

# Watch Job

## Overview

Monitoring a job should cost about **one turn**, not thousands. The expensive failure mode is *polling a job by re-reading its log file in a loop*: each turn re-reads the whole (growing) context, so cost scales with `turns × context size`. A real session burned **~$400** doing exactly this — a sub-agent ran **2,574 `Read`s** of the same log files. Don't loop; wait.

**Core rule: don't generate many turns to wait. Wait in one place, or let the harness wake you.**

## When to use

Any request to monitor / watch / wait for / babysit a running job, or to report when it finishes: training runs, builds, test suites, deploys, long shell commands, batch jobs, "tell me when it's done", overnight watching.

## The cheap ladder — use the first option that fits

1. **Background + notify** — run it detached (`run_in_background`, or `cmd &`) and let the harness wake you when it exits. **Zero model turns while it runs.** Best for multi-hour jobs.
2. **Monitor tool** — register the process and wait for its exit code, or for a completion/error pattern in its output. Interrupt-driven, not polling. (If the `Monitor` tool isn't loaded, search for it before hand-rolling a loop.) Since 2.1.271 every Monitor watch has a deadline (at most 30 minutes; 10 in `-p` runs) and asks to be re-armed — plan for re-arming, there is no `persistent` option.
3. **One blocking wait** — for jobs under the ~10-minute Bash timeout, a single tool call:
   ```bash
   while kill -0 <PID> 2>/dev/null; do sleep 30; done; tail -n 50 <log>
   ```
4. **Periodic check, only if forced** — read the **delta** (`tail -n 30 <log>`) and decide done-vs-running from `pgrep` / exit code. **Never `Read` the whole log, and never in a loop.**

## Hard rules

- **Watch from the MAIN thread. Never spawn a sub-agent to monitor.** Sub-agents default to the 5-minute prompt-cache tier; they get 1 hour only when `ENABLE_PROMPT_CACHING_1H=1` is set (it covers both buckets; ccage cages export it — measured 2026-10-05: a research sub-agent wrote 847,783 cache tokens at the 1-hour tier, 0 at 5-minute). A 5-minute watcher sub-agent rebuilds its cache on every spawn/gap and *is* the pattern that cost ~$400; even at 1 hour, a sub-agent watcher dies with its parent and costs a second context.
- **Never re-`Read` a whole log file in a loop.** One `tail -n N` per check, at most.
- **Keep each check's context tiny** (tail deltas, not full reads), so even a cache rebuild is cheap.
- **Don't poll on a short timer with full-context turns.** If you can't background it, block in one call or use the Monitor tool.

## Quick reference

| Situation | Do this |
|---|---|
| Runs minutes–hours, no decisions needed mid-run | Background + notify |
| Must stop at a specific log line / error string | Monitor tool (stream pattern match) |
| Short job (< ~10 min), just wait for exit | One blocking `while kill -0` call |
| Must report incremental progress | `tail -n 30` deltas on a timer — never full `Read` |
| Tempted to spawn a "monitor" sub-agent | Don't — watch from the main thread |

## Common mistakes

- **Re-`Read`ing the full (growing) log each check** → context balloons and is re-read every turn → runaway cost. Use `tail -n N`.
- **A monitoring sub-agent** → 5-minute TTL, cold cache rebuilds every spawn/gap. Watch on the main thread, or background + notify.
- **A blocking loop longer than the Bash timeout** → the tool call times out mid-wait. Background + notify for multi-hour jobs.
- **Polling every few seconds with fresh full-context turns** → thousands of turns. Monitor tool or background + notify.
