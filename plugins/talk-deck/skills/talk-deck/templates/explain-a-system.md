# Template: explain a practice or system

Optional. Use it for any slide whose job is to teach how a practice, tool or system
works (a backup routine, a code-review gate, a release process), so a technical
audience could build their own. Where it came from: the owner's corrections of
2026-11-22 (`SKILL.md`, section 3, "Problem before solution"): "So we need to explain
that first. Then we need to explain how we are solving it." Build it as a prototype
slide first (`SKILL.md`, section 2).

The pattern is incident, then mechanism, then recent number. Three bands, top to
bottom, on one slide of at most 80 closed words:

## 1. Without it (chips, no sentence)

One or two chips, each a failure that happens without the practice, each backed by
one dated incident. A chip opens one picture of that incident (a step strip, a
before and after pair, a time or size bar) with at most one grey note line. An
incident older than the recency window may appear here, dated, and nowhere else.

Generic examples:
- Chip "Backups never restored" opens a strip: nightly backup runs, restore never
  tested, disk fails (dated), restore fails.
- Chip "Reviews skipped under deadline" opens a before and after: unreviewed merge
  breaks the build (dated) against the same change reviewed by a gate.

## 2. How we do it (a row of boxes)

At most 6 boxes in a row with arrows. Each box: a kind badge (rule, hook, script,
tool), a name of at most 3 words, and the trigger on the arrow into it, at most 4
words ("after each commit", "at 80% disk"). Each box opens one picture plus at most
one note line, and a nested "Show the real text" layer holding an excerpt copied from
the live file at build time. A box with no real file says so in the facts file.

Generic example: restore-tested backups. Boxes: "Snapshot" (script, "nightly") then
"Copy offsite" (script, "after snapshot") then "Test restore" (script, "weekly") then
"Alert" (hook, "on failure").

## 3. What it gets us (at most 3 numbers)

At most 3 big numbers, each with a label of at most 7 words, all dated inside the
recency window, each with a row in the facts file. With no number in the window, show
one dated in-window event instead of an older number.

Generic example: "9 of 9" labelled "weekly test restores passed", dated, source "the
restore log".

## Facts rows for the example slide

```
| value | date | source |
|---|---|---|
| 9 of 9 | 2026-11-15 | the weekly restore log |
| 4 h | 2026-10-02 | the incident note for the lost disk |
```

## HTML skeleton (the checker's defaults apply)

```html
<section id="s5">
  <h1>Backups we have restored</h1>
  <details name="s5"><summary>Without a restore test</summary><p>One-line note.</p></details>
  <details name="s5"><summary>Snapshot, nightly</summary><p>One-line note.</p>
    <details name="s5-text"><summary>Show the real text</summary>
      <pre data-verbatim>excerpt copied from the live file at build time</pre></details></details>
  <p><b>9 of 9</b> weekly test restores passed</p>
</section>
```

Run `python3 scripts/check_deck.py deck.html --facts facts.md` before showing it.
