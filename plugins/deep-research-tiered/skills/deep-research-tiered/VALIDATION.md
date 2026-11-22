# deep-research-tiered — live validation record & final configuration

Date: 2026-06-05. Validation host project: a separate research repository (a quant-strategy question; the research outputs themselves live there — this doc is the skill-side record).

Skill files: this skill's directory (SKILL.md + workflow.js) · agents: the plugin's `agents/dr-*.md`.

## Final configuration (implemented 2026-06-05, all changes empirically validated)

| Stage | Agent | Model (explicit pin in workflow.js) | Notes |
|---|---|---|---|
| Search | dr-searcher | **Sonnet** low | Won the 3-tier A/B on discovery; refined-second-query behavior; prompt now encourages it + prefers HTML/abs over PDF links |
| Fetch/extract | dr-extractor | **Sonnet** low | Avoided all Haiku artifacts and the marketing-page trap Opus fell into; prompt mandates verbatim quotes + hedge/role preservation; arXiv `pdf/` URLs rewritten to `abs/` in code; zero-claim sources logged |
| Verify (central) | dr-verifier ×centralVotes | Sonnet high | **Three-way verdicts**: confirmed / unvalidated / refuted (shared rubric incl. vendor-doc authority line); checklist adds verify-against-source + arXiv publication-status check |
| Check (supporting) | dr-checker ×1 | Sonnet medium | Same three-way rubric, narrow scope |
| Appeal | dr-verifier ×1 | **Opus** | Only for claims finishing `refuted` from `primary` sources, capped by `maxAppeals` (default 5) |
| Synthesize | dr-synthesizer(-max) | session model, xhigh/max | Prompt grounded with `args.today` + no-provenance-judgments rule; reports `leads` (unvalidated) separately from findings |

Measured cost: smoke (maxFetch 4, 1 vote) ≈ $1.36 · full (maxFetch 20, 30 claims, 3 votes) ≈ $7.98 pre-upgrade → ≈ $8-11 with Sonnet search/extract + appeals. Bundled all-Opus baseline ≈ $110 → **~10× cheaper**. Verification ≈ 84% of spend.

## Bugs found live and fixed in workflow.js

1. **`args` delivered as JSON string** — the `typeof args === 'object'` guard silently discarded it; first launch died in 4 ms with "No research question". Fix: `JSON.parse` fallback.
2. **Fetch-budget starvation** — global first-come-first-served `fetchSlots` inside a no-barrier search→fetch pipeline let the first angle to return consume the entire budget (observed: 1 of 6 angles got all slots). Fix: barrier after Search + round-robin interleave selection across angles (verified live next run: 4/4/3/3/3/3 distribution).
3. **Binary verdict schema** (inherited from the bundled script) conflated "true but weak source" with "factually wrong" — the dominant source of report distortion. Fix: three-way verdicts + separate `leads` output.
4. **Synthesizer knowledge-cutoff artifact** — called a real Feb-2026 arXiv preprint "likely fabricated, future-dated" by reasoning from priors instead of verifier evidence. Fix: date injection (`args.today`) + grounding constraint; re-run verified the artifact gone.
5. **arXiv PDF fetches fail extraction** (3 PDFs → 0 claims, silently); paywalled SSRN/ScienceDirect/Springer also zero-claim at every model tier (fetch limitation, not model). Fix: URL rewrite pdf→abs + extractor prompt fallback to ar5iv + zero-claim logging. Paywalls remain a structural gap — targeted general-purpose hunt agents recovered 4/5 paywalled targets where the pipeline could not.

## Validation experiments (≈90 agents total across all phases)

### Model tiering + effort (smoke + full run transcripts)
- agentType→model pinning works (verified via `.meta.json` + transcript model fields, both runs).
- **Frontmatter `effort:` NOT validated**: zero thinking blocks in every transcript, including dr-verifier (`effort: high`) and dr-synthesizer-max (`effort: max`). Either not applied to workflow subagents or thinking stripped from transcripts — indistinguishable. (Answers the open question from the build night. `xhigh` synthesizer frontmatter value still unexercised.)

### Verification A/B — 16 killed primary-source claims re-run on Opus, identical prompts
- 9 flips / 7 upholds. All 3 sampled *judgment* kills (marketing, source quality) upheld with sharper evidence; *factual* kills from peer-reviewed sources flipped (5 report-material false kills: missed journal status in arXiv comments field, judged quote instead of document, extraction-wording artifacts). Opus single votes show noise too (confirmed one vendor marketing claim while refuting a comparable one).

### Three-way verdict pilot — 12 claims on Sonnet
- 9/12 in expected category, **zero false "refuted"**, false kills recovered at the Sonnet tier without Opus. Systematic drift found and rubric-fixed: vendor product-capability claims migrated confirmed→unvalidated until the vendor-doc authority line was added.

### Prompt-fix test — Sonnet with added checklist lines
- Publication-status line: 3/3 Sonnet verifiers found the journal DOI (0/3 without it).
- Verify-against-source line: rescued both quote-truncation false kills, diagnosing the truncation explicitly.
- Residual: a claim with genuinely wrong wording (extractor misattributed selection-stage tests to "signal generation") still correctly died — root cause is extraction wording, which the Sonnet extractor fixes.

### Per-stage search/extraction A/B (2 angles / 2 sources per tier)
- **Search:** Haiku admitted junk rated "high" (self-promotional preprint ×2 angles, content-farm journal); Opus avoided junk, calibrated best; **Sonnet won discovery outright** — found BIS WP 1087 (neither other tier found it) + 4 more credible new sources, driven by a refined second query; one calibration slip (practitioner blog rated "high"). Discovery > calibration: verification catches over-rating; nothing recovers an unfound source.
- **Extraction:** academic paper — Opus best (perfect role attribution), Sonnet good, Haiku artifact-laden (hedge-stripping, list truncation, role misattribution). Marketing page — **Sonnet best; Opus fell into the same L2/L3 overreach as Haiku.** Net: Sonnet ≈ Opus, both ≫ Haiku.

### Grounded synthesis re-run
- Same inputs + grounding header: cutoff artifact gone, refutations reported neutrally, quality otherwise comparable.

## Quality-parity verdict vs bundled /deep-research

No full head-to-head was run (deliberate). Per-stage evidence: search = Sonnet ≥ Opus in test; extraction = split 1-1; verification = fixed-Sonnet matched Opus verdicts on all A/B claims; synthesis = same model + grounding fix. The bundled script (which this forked) retains the binary verdict schema, no grounding, no publication-status check — so the tiered fork is ahead on report-honesty design while ~10× cheaper. Residual risk: single-sample noise per stage; revisit if a future run shows source-pool weakness.

## Known open items

- `effort:` frontmatter behavior on workflow subagents (above) — needs a harness-level answer, not more transcript grepping.
- `xhigh` as a frontmatter effort value unexercised (default dr-synthesizer path).
- Paywalled academic sources: pipeline cannot reach them; the working pattern is a follow-up general-purpose hunt agent (SSRN download links, author pages, open-access mirrors) — candidate future stage.
- Per-token pricing used for $ conversions was not re-verified against current published rates; re-check before quoting externally.
