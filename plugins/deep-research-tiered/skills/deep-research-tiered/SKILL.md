---
name: deep-research-tiered
description: Cost-tiered deep research — decompose the question in-session, get user approval on angles and cost, then run a Sonnet-tiered fan-out workflow (search → fetch → three-way verify with Opus appeals → synthesize) and present a cited report. Use when the user asks for deep research, multi-source research, a fact-checked report, or types /deep-research-tiered. Roughly 10× cheaper than the bundled /deep-research on our measured runs, because search/fetch/verify run on Sonnet instead of the session model.
---

# Tiered deep research

A cost-tiered fork of the bundled `deep-research` workflow. The expensive fan-out only starts after the user approves the scope, and every stage runs on the cheapest model that can do its job. Never invoke the bundled `deep-research` workflow from this skill — the whole point is the tiered variant.

## Step 1 — Clarify (only if needed)

If the question is underspecified (e.g. "what car should I buy" without budget/use-case/region), ask 2-3 clarifying questions first and weave the answers into the question. If it is already specific, skip this step — do not add friction.

## Step 2 — Decompose in-session

Decompose the question into 4-6 complementary search angles yourself, in this session. Do NOT spawn an agent for this. Each angle: a short `label`, a concrete web-search `query`, and a one-line `rationale`. Pick angles that suit the domain (e.g. broad/primary · academic/technical · recent news · contrarian/skeptical · practitioner/implementation). Make queries specific enough to surface high-signal results; avoid redundancy.

## Step 3 — Approval gate (mandatory)

Present to the user before launching anything:

1. The angles (label + query, one line each).
2. The caps: `maxFetch` (default 15 sources), `centralVotes` (default 3), `maxVerifyClaims` (default 25).
3. A cost estimate. Agent count ≈ angles + maxFetch + (central claims × centralVotes) + supporting claims + appeals (0-5) + 1 synthesis. At defaults expect ~50-70 agents — on our test runs roughly an order of magnitude cheaper than an all-session-model deep research run (exact dollar cost depends on current per-token rates and your account; a smoke-scale run at maxFetch 4 / centralVotes 1 is a small fraction of the full-scale cost).
4. Synthesis effort: default xhigh; offer `max` for the deepest final report (costs little extra — one agent).

Let the user trim angles or caps. Do not launch until they confirm.

## Step 4 — Launch

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/skills/deep-research-tiered/workflow.js",
  args: {
    question: "<refined question>",
    angles: [{ label, query, rationale }, ...],
    today: "<YYYY-MM-DD>",  // ALWAYS pass today's date — grounds the synthesizer against knowledge-cutoff artifacts
    maxFetch: 15,          // omit for default
    centralVotes: 3,       // omit for default
    maxVerifyClaims: 25,   // omit for default
    maxAppeals: 5,         // omit for default — Opus appeal votes for refuted primary-source claims
    synthEffort: "max",    // only if the user chose max; omit for xhigh default
  },
})
```

The workflow runs in the background; relay progress if the user asks. Stage→model mapping (validated by per-stage A/B, 2026-06-05): dr-searcher + dr-extractor = **Sonnet** low (Sonnet beat both Haiku and Opus on search discovery; Sonnet extraction avoided all Haiku artifacts and beat Opus on marketing-page overreach); dr-verifier = Sonnet high, **three-way verdicts** (confirmed/unvalidated/refuted) with counter-search; dr-checker = Sonnet medium (supporting claims, source-check); refuted primary-source claims get one **Opus appeal** vote; dr-synthesizer(-max) = session model at xhigh/max with date-grounded prompt.

## Step 5 — Present AND persist the report

When the workflow completes, FIRST write the full report to disk, then present it in chat.

**Persist (mandatory):** write `./research/<topic-slug>.md` in the current project (create the directory if needed; if the slug already exists, suffix `-2`, `-3`, …). The doc must contain: the date, the refined question, the args used (angles, caps, synthEffort), the executive summary, every finding with confidence + source URLs, the refuted-claims appendix, caveats, open questions, the stats block, and a one-line cost note (tokens/cost if known). This file is the durable artifact — the chat presentation is a view of it. Do not commit it; leave that to the user.

Then present from the return value:

- **Executive summary** (the `summary` field) first.
- **Findings** with confidence + sources — cite URLs as markdown links.
- **Unvalidated leads** (the `leads` field) — claims the source genuinely makes but whose quality/independence fell short; present as follow-up material, clearly separated from findings.
- **Refuted claims** appendix (one line each) — transparency about what was killed (note any that survived appeal).
- **Caveats and open questions.**
- **Stats line**: sources fetched, claims extracted/verified/confirmed/unvalidated/killed, appeals + overturns, tangential dropped, agent calls — so the user sees what the run actually did and what it skipped.

Report outcomes faithfully: if most claims were refuted or sources were weak, say so plainly — do not inflate confidence.

## Troubleshooting

- `Unknown agent type 'deep-research-tiered:dr-...'`: the plugin's bundled agents aren't registered in this session — run `/reload-plugins`, or start a new session so the plugin's `agents/` directory loads.
- Workflow tool unavailable: dynamic workflows are disabled — check /config.
- To validate cheaply after any change: run with `maxFetch: 4, centralVotes: 1` on a small factual question.
