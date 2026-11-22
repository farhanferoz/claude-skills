---
name: ai-patterns
description: Detect and reduce formulaic "AI writing" patterns in prose — the participial consequence clause, the fronted transition adverbial, overrepresented vocabulary. Use when writing or reviewing any prose a human will read — a blog post, research report, design doc, README, PR description, changelog, or generated article — and when asked to "remove AI patterns", "make this sound less like AI", "de-slop", "check for AI writing", "humanise this", or before publishing generated text. Also use when setting a project's writing-quality baseline, or when deciding whether a style rule is worth enforcing. NOT an AI-detector: it cannot tell you whether a human wrote something, and must never be used to judge that.
---

# AI writing patterns

## What this is, and the one thing it is not

This measures **style drift against a baseline you calibrate from your own corpus**. It does not detect authorship, and it must never be used to decide whether a person wrote something.

That limit is not modesty, it is the evidence:

- **Liang et al. 2023** (*Patterns*, Cell Press; [arXiv:2304.02819](https://arxiv.org/abs/2304.02819)) tested 7 commercial detectors on 91 TOEFL essays and 88 US 8th-grade essays. Non-native writing drew a **61.22% average false-positive rate — 97.8% flagged by at least one detector** — against ~5.19% for native writers. The mechanism is perplexity: plain, low-variability prose reads as machine-like.
- ***Matter of Newby v. Adelphi University***, 2026 NY Slip Op 26021 (NY State Supreme Court, Article 78). A student was disciplined on a ~100% AI flag; the court annulled it as "without valid basis."

Pattern-matching cannot separate "written by a machine" from "written plainly, formally, or by someone whose first language isn't English." Output is a **hint to investigate**, never a verdict, and never an unappealable gate.

## The method: measure your own baseline first

Published thresholds are worthless second-hand. Two popular rule sets disagree by 2x on the same rule (one says at most one em-dash per 500 words, another per 1,000), and neither shows any data.

The defensible method is the one **Kobak et al.** used (*Science Advances* 2025, [arXiv:2406.07016](https://arxiv.org/abs/2406.07016)) across 15.1M PubMed abstracts: compare observed rates to an **empirically derived, corpus-specific baseline**. Their excess-vocabulary analysis only works *because* a stable human baseline existed to deviate from — `delve`, `pivotal` and `underscore` were all present at unremarkable rates before 2022.

So:

```bash
# 1. What does normal look like here?
${CLAUDE_SKILL_DIR}/scan.py docs/ --baseline .ai-patterns-baseline.json

# 2. Did what I just wrote drift?
${CLAUDE_SKILL_DIR}/scan.py draft.md --compare .ai-patterns-baseline.json
```

`scan.py` is stdlib-only, so it runs in any repo with no environment. Rates are per 1,000 words of prose; code blocks, inline code, link targets and image markup are excluded.

**Never flag presence alone.** Every construction below is ordinary English. `Moreover` sits at a stable 3.3e-5–5.1e-5 frequency in Google Ngrams from **1950 to 2019** — humans have opened sentences that way for seventy years. A presence-based rule measures register, not authorship.

## Rules, by how much evidence stands behind them

Sorted honestly. Several rules that circulate as established turn out not to be, and one I assumed was folklore has the best study behind it.

**Corpus-confirmed.**

1. **Overused vocabulary.** Two independent studies, different methods, same corpus family: Kobak et al. give `delves` r=28.0, `underscores` r=13.8, `showcasing` r=10.7; Matsui (*Perspectives on Medical Education* 2025) independently confirms `delve, underscore, meticulous, showcase, intricate, tapestry, pivotal, realm, landscape`. Population signal only — no labelled per-document accuracy — so **advisory and density-based, never an error**. Keep the list *short and rare*: Kobak's biggest movers include `potential`, `findings` and `crucial`, and flagging those would fire on ordinary English.
2. **Em-dash density — better evidenced than the structural rules, which surprised me.** Czuma 2026 ([arXiv:2606.29540](https://arxiv.org/abs/2606.29540)) is pre-registered, 69,632 medRxiv preprints, clustered SEs: presence rose **4.23% → 11.58%** post-ChatGPT (OR 2.96, 95% CI 2.77–3.17), rising 4% → 8.0% (2024) → 20.3% (2025) — tracking *adoption*, not release date. Still report-only, because the strong popular version ("em-dashes mean AI, today, for all models") is folklore: several current models sit at or below the human baseline.
3. **Clause-packing / syntactic complexity.** ArguGPT ([arXiv:2304.07666](https://arxiv.org/abs/2304.07666)), 4,038 essays: *"machines produce sentences with more complex syntactic structures while human essays tend to be lexically more complex."* This is the nearest support for the participial-consequence rule — a trailing `…, ensuring X` is literally clause-packing — but no study isolates that construction by name, and Bao et al. found the *opposite* direction in abstracts, plausibly a genre effect.

**House-style only — flag these against your own baseline, not as evidence of anything.**

4. **Participial consequence** (`…, ensuring X`, `…, enabling X`, `…, allowing X`, `…, leading to X`). Supported indirectly by (3); no direct study.
5. **Fronted transition adverbial** (`Moreover,` `Crucially,` `Furthermore,`). **Do not present this as an AI tell.** No primary corpus study supports it; ArguGPT's trigram table does not surface `moreover`/`furthermore` as distinguishing for either class; and Bao et al. measured *decreased* connective use post-ChatGPT — so the rule may point backwards. It is still a legitimate *house-style* rule if your own corpus shows you overusing it.
6. **Templated frames** (`not only X but also Y`, `plays a critical role in`, `paves the way for`). Widely repeated, **no corpus study isolates the template** — it is an inference from word-level data that got restated as measurement.

**Actively unsupported — do not quote these numbers.** The circulating "burstiness" figures (human sentence-length SD ≈ 8.2 vs GPT-4o ≈ 4.1) trace back only to AI-detection marketing sites with no dataset or method. `cornerstone` appears in every listicle and in **no** primary excess-word list.

## If you are writing: describe the target, don't list the ban

**Do not enumerate forbidden words in an instruction to a model.** Anthropic's own prompt-engineering guidance says it directly for style control: *"Tell Claude what to do instead of what not to do"* — *"Instead of: 'Do not use markdown' / Try: 'Your response should be…'"*. ReboundBench ([arXiv:2511.12381](https://arxiv.org/abs/2511.12381)) offers a mechanism: negation raises the internal probability of the very token being suppressed. (Caveat: measured at token level in smaller open models, not end-to-end in a modern chat model.)

Use a positive target instead:

> Vary how sentences open, and never begin two consecutive sentences the same way. Write a consequence as its own sentence with a plain subject and verb, rather than appending it to the previous clause. Prefer active voice, and prefer a concrete specific over an abstract claim.

**A prompt ban is not enforcement.** Measured in one real pipeline whose prompts already forbade `seamless`, `frictionless`, `delve`, `tapestry`, `robust` and nine more: **51 occurrences of explicitly banned vocabulary still shipped** across 256k words. Whatever you put in the prompt, measure the output.

## If you are fixing: what is safe to automate

**Safe.** Deleting a sentence-initial transition adverbial and recapitalising leaves a grammatical sentence with identical meaning.

**Not safe.** Everything else. The clause after `, ensuring` *carries meaning* — deleting it drops a claim, and rewriting it needs an entailment check. In one measured case an over-eager auto-strip produced **17 false positives across 13 real documents**. Rewrite by hand, or behind a fidelity gate that checks numbers and entailment.

## Prior art

Nine independent rule sets exist; vocabulary lists converge strongly across them, thresholds do not.

| Source | Licence | Notes |
|---|---|---|
| [Wikipedia: Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing) | CC BY-SA 4.0 | ~15k words, WikiProject AI Cleanup; the most complete |
| [conorbronsdon/avoid-ai-writing](https://github.com/conorbronsdon/avoid-ai-writing) | MIT | 4.2k stars; honest about detector false positives |
| [tbhb/vale-ai-tells](https://github.com/tbhb/vale-ai-tells) | MIT | 133 Vale rules |
| [NikhilVerma/writinglint](https://github.com/NikhilVerma/writinglint) | MIT | The rigorous one: dependency-parse rules with an eval harness that tests which rules actually discriminate |

Check citations before borrowing. One 447-star repo cites "Buffer's 52M post analysis" as evidence; that conflates two different Buffer reports, neither about AI writing patterns.

## What this tool was actually validated against

Measured 2026-09-08. Small, and stated plainly rather than averaged into a reassuring headline number.

| Check | Result |
|---|---|
| Auto-correction preserves meaning | **37 edits across 92 real posts, all meaning-preserving.** Every one drops a sentence-initial adverbial and recapitalises: *"…risk profile. Crucially, your time horizon directly impacts…"* → *"…risk profile. Your time horizon directly impacts…"* |
| Separation from human prose | Human pre-LLM control (9 Python PEPs, 47k words): **0.17/1k**. LLM-generated blog corpus (92 posts, 257k words): **0.43–0.48/1k**. About **2.8x**. |
| Does it fire on humans? | **Yes — 0.17/1k, not zero.** PEP 572 scores 0.44/1k. This is why density beats presence. |
| Scanner vs hand count | Reproduces a hand measurement exactly (0.482 vs 0.48). |

**Known limits of this validation.** One control corpus, one genre (specification prose vs blog posts), so 2.8x is directional and not a precision figure. No labelled ground truth, so there is **no false-positive rate to quote** — and any tool that quotes one without saying how it was conditioned is repeating Turnitin's mistake, whose "<1%" applies only to documents already scored ≥20%.

## Checklist

- [ ] Baseline measured for this corpus, not inherited from a blog post
- [ ] Structural rules acted on; vocabulary advisory; punctuation report-only
- [ ] Generator instructions phrased as a positive target, not a ban list
- [ ] Output measured — a prompt rule is not enforcement
- [ ] Only transition-adverbial deletion automated; everything else by hand
- [ ] Nobody's authorship judged on this output
