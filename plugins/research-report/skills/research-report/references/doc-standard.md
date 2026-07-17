# Research-doc authoring standard (`notes/research/`)

Written after the drifting64 assessment doc cost many review cycles. Follow it for any
doc that explains code, math, or experiment results.

**Goal: a reader can follow it cold, and every claim is true.**

## 1. Source-first — before writing a single claim
- Open and read the actual implementation you're describing (the functions, not a
  paraphrase from memory). Note the exact files/symbols you relied on.
- Fetch the actual numbers from the data source (W&B / logs) *this session*, from the
  **same pull that generates the figures**. Every quantitative statement must trace to a
  value you pulled, not one you recalled. Compute extrema (peak / min / final / argmax)
  over the **full series**, never a convenience window — an `argmax` over the first 30
  epochs is how "peak at epoch 29" shipped when the true peak was epoch 51.
- For each figure you'll show, confirm in the plotting code exactly which column and
  which split (train / val / test) it plots.

## 2. Define before you narrate
- Write a **Notation** block first: every symbol defined once (`g, t, T, ⟨·⟩`, …).
- Write a **Definitions** block next: every named term, with its formula when one
  exists, *before* it appears in prose.
- **No dangling symbols.** If `c` appears, `c` is defined there or links to where it is.
  Define inline; the appendix *derives*, it is not where basic terms are introduced.
- Expand every acronym on first use (AD, CNS, NRMSE, SSR, …).

## 3. Figures: code + caption + prose must agree
- The caption/title states the data basis: which metric, train vs val.
- The plotting code must match the caption (verify the column actually plotted).
- The prose describing a figure must match the figure (same split, trend, numbers).

## 4. Data and figures move together (snapshot integrity)
A snapshot doc ("as of epoch N / date D") drifts the moment its figures and prose come
from different data states — the failure that shipped a doc whose Fig 5 bars (epoch ~96)
contradicted its own provenance table (epoch ~80).
- **One anchor.** Pick a single snapshot point (epoch / date / commit), state it once,
  and derive *every* number and figure from it.
- **Pin the figures.** Snapshot figures must be cut to that anchor in the plotting code
  (e.g. filter `epoch ≤ N`), so re-running the script cannot silently advance them past
  the prose.
- **Same pull.** Hardcoded prose numbers come from the same data pull as the figures.
  If you regenerate figures, re-pull and re-verify the prose numbers in the same pass —
  regenerating one without the other is exactly what breaks the anchor.

## 4b. Math is typeset as math, never as code (user-flagged)
- **Formulas go in LaTeX math** — inline `$...$` for symbols and short relations,
  **display math** (`$$...$$`) for any load-bearing equation (a definition, a loss, an
  SDE, anything with a fraction / sum / norm). A formula crammed inline that would read
  better displayed gets displayed.
- **Backticks are for code only**: identifiers, file paths, config keys, CLI commands,
  run ids. The moment a backtick span contains a Greek letter, an operator (≈ → ‖ ·) or
  `sqrt(`, it is a formula pretending to be code — convert it.
- Inside math delimiters write **pure-ASCII LaTeX** (`\lambda`, `\sigma`, `\sqrt{}`,
  `\lVert`), not unicode glyphs, so rendering never depends on per-doc unicode shims.
- The build script must enforce this (see hard guards below).

## 4c. Calibration/ensemble studies: reliability bracketed by lead time (user-flagged)
A single one-step reliability diagram plus a coverage@0.90-vs-lead curve is **not
enough**: tail miscalibration at mid/late leads stays invisible. The standard format
(established in `drifting_vs_baselines_2026-06-01` and `energy_score_drifting_results`):
- a **panel of full reliability diagrams (observed vs nominal, all levels incl. 0.95/0.99)
  bracketed by lead-time windows** — e.g. one-step + early/mid/late rollout windows —
  one panel grid per dataset, shared legend, diagonal in every panel;
- organised, not dumped: fixed window set across datasets, same model colours everywhere,
  equal-aspect axes;
- plus the per-lead coverage@0.90 + calibration-error curves for the trajectory view.
Keep the underlying per-lead, per-level coverage in the analysis record (JSON/CSV) so the
panels can be replotted without re-running ensembles.

## 5. One whole-doc audit before showing the user
A top-to-bottom pass; fix everything at once, not symptom-by-symptom:
- [ ] every symbol/term defined before first use
- [ ] every number traces to a fetched source
- [ ] all figures and all prose numbers share one stated snapshot (epoch / date / commit)
- [ ] every figure labelled with its split; caption matches code; prose matches figure
- [ ] **artifact ledger reconciled** — every results table and figure produced for this doc is either surfaced (as a table/figure) or consciously excluded with a reason; no computed grid/breakdown is left as a prose paraphrase, and no generated figure sits unembedded (mirror of the claims ledger; enforced for figures by the `report-figures:` manifest + guard)
- [ ] universal claims ("all / every / none / always") checked against each instance
- [ ] every "Fig N" / "§N" cross-reference resolves and is consistent
- [ ] every acronym expanded once
- [ ] PDF builds; skim the rendered output
- [ ] **no "section 0"** — the summary stays unnumbered; numbering starts at 1 (user-flagged, twice)
- [ ] **math in math mode** — no formulas inside backticks; display math for load-bearing equations; ASCII LaTeX inside `$...$` (§4b; user-flagged)
- [ ] **ASCII only inside code spans** — no √ ½ ‖ ⟨⟩ ′ ḡ etc.; write `sqrt(...)`; the build script must guard for these
- [ ] **reliability diagrams bracketed by lead-time windows** for any ensemble-calibration doc (§4c; user-flagged)
- [ ] **figures placed in-section** — use `\floatplacement{figure}{H}` (float package) so figures render where written instead of piling up pages later
- [ ] **tables**: column widths are set **automatically** by the shared `_build/auto_table_widths.lua` filter (each column sized to its longest rendered cell) — write plain `|---|` delimiters and wire the filter into the build (hard guards below). Never hand-tune dash-runs; the old "uniform `|---|` gives a 50/50 split / tiny label column with a dead gap" failure is now mechanically prevented.
- [ ] **tables**: keep cells single-line — pandoc CLIPS multiline-cell rows at page breaks (silently loses rows)
- [ ] **plots**: axes dynamic around the data (always including any reference line, e.g. nominal 0.90) — a fixed 0–1 axis squashes clustered curves into unreadability
- [ ] read the rendered PDF **page by page** — three of the rules above were only ever caught that way

**Hard guards (copy into every `build_pdf.sh`):**

1. **Proportional table widths (mechanical).** Resolve the shared filter
   depth-independently and pass it to pandoc, so the uniform-`|---|` 50/50-split gap
   can no longer ship — table widths are no longer a manual-audit item:
   ```bash
   _D="$(cd "$(dirname "$0")" && pwd)"
   while [ "$_D" != "/" ] && [ ! -e "$_D/_build/auto_table_widths.lua" ]; do _D="$(dirname "$_D")"; done
   TBLFILTER="$_D/_build/auto_table_widths.lua"
   pandoc "${DOC}.md" ... --lua-filter "$TBLFILTER" -H "$HDR"
   ```
2. **Grep guards — the build must `exit 1` on:** (1) a `^#+ 0[. ]` section-0 heading,
   (2) a literal `√` anywhere, (3) math chars or formula hints inside backtick spans,
   (4) unicode Greek/operators inside `$...$` spans — see
   `energy_score_drifting_results_2026-06-04/build_pdf.sh` for the token-aware reference.

Checklist items that still cannot be grepped (float placement) are owned by the
page-by-page audit; table widths no longer are.

If a box can't be ticked, fix it before the doc leaves your hands.

## Workflow that front-loads quality
Draft the **outline + Notation + Definitions + the list of claims to verify** first and
confirm the structure, *then* write prose. This catches scope/term gaps before they're
buried in paragraphs.

Keep a **claims ledger** while drafting — a table of (claim → value → which pull it came
from). Every number in the prose gets a row; that is what makes a stale number *visible*
instead of trusting recall.

**This standard governs itself.** It and the figure-generation scripts are subject to the
same audit. When a failure slips through (as snapshot-drift did here), patch the standard
so the next doc has a tripwire for it.
