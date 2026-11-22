---
name: figure-workflow
description: >-
  Procedure for making a results figure or interactive figure page that a person
  will review, from agreeing its message to handing over rendered, checked output.
  Use when asked to make, draw, plot, redraw or finalise a figure, a results
  figure, a summary figure, an interactive/HTML figure page, a dashboard of
  results, or an architecture diagram for a study, and when revising one after
  the owner's comments. Built from two days of owner corrections (2026-09-29,
  2026-10-19).
---

# Figure workflow

Every rule below exists because the owner had to ask for it. Sources, with quotes:
the owner's two lessons notes of 2026-09-29 and 2026-10-19, kept in a private research repository (what did not work,
and what did).

## 1. Before drawing

1. **Inventory.** If the figure compares models or arms, first give a table: name, one-sentence
   description, include yes/no with a reason. The owner decides inclusion item by item.
2. **Names.** Short names that describe the thing, one scheme across all families, the
   distinguishing parameter in brackets ("Lead-conditioned (first block, retrained)"). Never
   rename an established term once agreed.
3. **Message first.** State the one thing a reader should see at first glance and get it agreed.
   If you cannot state it, the figure is not ready to design.
4. **Coverage.** Every case the study covers is on the figure, or its absence is stated. Build all
   cases before claiming a headline: a message true on two setups can flip on the third.
5. **One case first.** Build one case (one setup, one panel set), have it reviewed, then generate
   the rest.

## 2. Design rules

**Every panel earns its place (owner 2026-10-19, one figure round; check each item before showing a figure).**
- Each panel adds information no other panel shows (two near-identical panels: drop one) and links to a
  measured result; a measure that explains nothing measured is dropped (figure 3: "Is it good? Is it bad? I
  have no idea"). Expected behaviour is one sentence of text, not a figure.
- Each panel carries the reference that says good or bad: a target line (spread / error = 1), the simulator
  floor, the twin, the true one-step change. The figure the owner called "a very good test" was exactly that.
- One question per figure: panels that are "not related at all" become two figures.
- One quantity per panel, one y scale: never twin axes.
- One quantity, one scale everywhere it appears (not linear in one figure and log in another); a ratio the
  text states must be visible as that ratio on the axis.
- One view per quantity: continuous against wavenumber, not bands of the same curve as well.
- Main figure = the main models only, one colour and one line each, colours fixed across every figure;
  variants (grey runs) get their own diagnostics figure with one question. Even density: not "sometimes too
  sparse, sometimes too busy".
- Cost = time per forecast step, as bars, machine / precision / batch on the panel's face; no operation counts.
- Accuracy across models: shared model rows, dot + 95% interval, never a grid of scatters.
- Every system a model has: draw what exists, mark absent or unpublished cells; never leave one out silently.
- Every colour map has a colour bar with units. No empty panel or slide.
- A figure is explained to the owner in a few short lines, one block at a time, not paragraphs.
- Measures dropped from a figure stay in the comparison table; dropping is proposed to the owner, never silent.

- **Architecture figures are pictures, not words** (owner 2026-10-18, "surely we can do better than that ...
  here it's just words"; the redraw: "much better fig ... follow this in future too"). Draw what happens to a real
  input: a real data snapshot (channels as stacked layers); the grid with its tokens (every point, or the patch grid
  with one patch pulled out and enlarged); each token as a bar of one cell per number, coloured by the data's values
  in the order the code flattens them; totals on one scale across models; codecs as volumes (face = spatial size,
  depth = channels; frozen hatched); a shared network as one shared box. Labels a few words each; every size
  measured from the run's config. autocast: `autocast.utils.architecture_picture.ArchitecturePicture` does this.
- **Realisations before summaries.** Show raw runs from one start against steps before any
  aggregate.
- **Each panel says what it aggregates over** (runs, starts, sites, seeds). A single run is a
  line; a matrix needs an ensemble.
- **Same axis = same quantity.** Before putting two lines on one axis, or plotting against a
  derived axis, check the quantity is a function of that axis alone.
- **Paired measures sit side by side** on a shared axis, never behind a tab or toggle. Which measures
  get a panel follows the message (above); the rest stay in the table. (2026-09-29 said every measure gets
  a panel; 2026-10-19 trimmed figure 1 to three panels on the owner's word.)
- **Every mark type in the legend** (bars, whiskers, circles, stars, dashed lines).
- **Crowding:** a static figure keeps its main models and moves variants to their own figure (above);
  an interactive page may keep all items with context faint and hover/click focus. Never drop silently.
- **Text:** nothing a reader must read to understand the figure. Axis label = a few words that
  define the term ("RMSE of best forecast ÷ field std"); a longer definition goes in the panel
  title; dashed reference lines get one-word labels. No glossary. Numbers go in hover tooltips,
  verdicts in one-word coloured chips.
- **Layout:** row headings instead of a subtitle repeated over every panel; stack paired panels
  vertically when side by side is busy.
- **Colour scale** must make the pattern visible; if it hides it, fix the scale.
- **Uncertainty on every system**, and its method stated (e.g. 95% interval by resampling starts).

## 3. Numbers

- Walk the owner through how each plotted number is computed before calling it final; pick the
  standard estimator (e.g. pooled RMSE over starts, not a mean of per-start roots) and a reference
  whose 0 and 1 mean something (e.g. divided by the long-run-average forecast's error).
- **The figure script writes a companion `.md` (how each quantity is computed, counts of starts,
  members, seeds) and a `.csv` (every plotted value).** That detail stays off the figure.
- Generate any headline sentence from the data, so it cannot drift from what is drawn.
- Readings use precise language: no "quickly", "roughly", "about the same" without a number.

## 4. Files and hand-over

- `figures/` (with `final/` for approved ones) separate from `artefacts/`; content names, dated.
- Render and look at every view before handing over: open the PNG; for HTML take a headless
  screenshot of each state (headline, full, each setup).
- Hand over full absolute paths. When a figure is dropped, delete it and its README lines the same
  turn; when asked to "update the figure", update every figure the change touches.
