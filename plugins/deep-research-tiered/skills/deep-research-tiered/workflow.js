export const meta = {
  name: 'deep-research-tiered',
  description: 'Model/effort-tiered deep research: Sonnet search+extract, Sonnet three-way verify with Opus appeals, session-model synthesis',
  whenToUse: 'Launched by the deep-research-tiered skill after the user approves scope. Args: {question, angles: [{label, query, rationale?}], today?, maxFetch?, centralVotes?, maxVerifyClaims?, maxAppeals?, synthEffort?}.',
  phases: [
    { title: 'Search', detail: 'One Sonnet searcher per approved angle (refined second query allowed)', model: 'sonnet' },
    { title: 'Fetch', detail: 'URL-dedup, round-robin selection, fetch top sources, extract falsifiable claims', model: 'sonnet' },
    { title: 'Verify', detail: 'Three-way votes (confirmed/unvalidated/refuted) + Opus appeals for refuted primary-source claims', model: 'sonnet' },
    { title: 'Synthesize', detail: 'Merge dupes, rank confidence, separate findings from unvalidated leads (session model, xhigh/max)' },
  ],
}

// Tiered fork of the bundled deep-research workflow (extracted from CC 2.1.165).
// Config validated empirically 2026-06-05 (see ccage docs): per-stage model A/B
// (Haiku/Sonnet/Opus search + extraction), 16-claim verification A/B vs Opus,
// 12-claim three-way verdict pilot, prompt-fix tests, grounded-synthesis re-run.
// Differences from the bundled script:
//   - No Scope phase: angles are decomposed and user-approved in-session (by the
//     deep-research-tiered skill) and passed via args. Saves one agent + adds a gate.
//   - Search runs on Sonnet (beat Haiku AND Opus on discovery in A/B; Haiku admitted
//     junk sources rated "high"). Extraction runs on Sonnet (avoided every Haiku
//     artifact: hedge-stripping, role misattribution, marketing-page overreach —
//     and beat Opus on the marketing-page trap).
//   - Verify uses THREE-WAY verdicts (confirmed/unvalidated/refuted) instead of
//     binary refuted — the binary schema forced "true but weak source" and
//     "factually wrong" into the same kill bucket (validated as the main source
//     of report distortion). Central claims get centralVotes Sonnet verifiers with
//     counter-search; supporting claims get 1 Sonnet quote-check.
//   - Appeal lane: claims finishing refuted from a primary source get ONE Opus
//     appeal vote (in the 16-claim A/B, Sonnet false kills concentrated exactly
//     in primary-source factual claims; Opus overturned all of them).
//   - Synthesis prompt is grounded (today's date + no provenance judgments beyond
//     verifier evidence) — fixes a knowledge-cutoff hallucination observed live.
//   - Tangential claims are dropped from verification (logged + counted, never silent).
//   - All caps overridable via args for cheap smoke runs.

// ─── Args ───
// Some harness paths deliver args as a JSON string rather than an object; accept both.
let _a = args
if (typeof _a === 'string') {
  try { _a = JSON.parse(_a) } catch (e) { _a = null }
}
const A = (_a && typeof _a === 'object') ? _a : {}
const QUESTION = (typeof A.question === 'string' && A.question.trim()) || ''
const ANGLES = (Array.isArray(A.angles) ? A.angles : [])
  .filter(a => a && typeof a.label === 'string' && typeof a.query === 'string')
if (!QUESTION) {
  return { error: 'No research question. Pass args: {question, angles: [{label, query, rationale?}]}.' }
}
if (ANGLES.length === 0) {
  return { error: 'No search angles. Decompose the question in-session (skill step) and pass angles via args.' }
}
const MAX_FETCH = (Number.isInteger(A.maxFetch) && A.maxFetch > 0) ? A.maxFetch : 15
const CENTRAL_VOTES = (Number.isInteger(A.centralVotes) && A.centralVotes > 0) ? A.centralVotes : 3
const CENTRAL_KILL = Math.floor(CENTRAL_VOTES / 2) + 1 // majority refutes kill: 3→2, 1→1
const MAX_VERIFY_CLAIMS = (Number.isInteger(A.maxVerifyClaims) && A.maxVerifyClaims > 0) ? A.maxVerifyClaims : 25
const MAX_APPEALS = (Number.isInteger(A.maxAppeals) && A.maxAppeals >= 0) ? A.maxAppeals : 5
const SYNTH_TYPE = A.synthEffort === 'max' ? 'dr-synthesizer-max' : 'dr-synthesizer'
// Scripts cannot call Date.now(); the skill passes today's date for synthesis grounding.
const TODAY = (typeof A.today === 'string' && A.today.trim()) || ''

// ─── Schemas ───
const SEARCH_SCHEMA = {
  type: 'object', required: ['results'],
  properties: {
    results: {
      type: 'array', maxItems: 6,
      items: {
        type: 'object', required: ['url', 'title', 'relevance'],
        properties: {
          url: { type: 'string' },
          title: { type: 'string' },
          snippet: { type: 'string' },
          relevance: { enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}
const EXTRACT_SCHEMA = {
  type: 'object', required: ['claims', 'sourceQuality'],
  properties: {
    sourceQuality: { enum: ['primary', 'secondary', 'blog', 'forum', 'unreliable'] },
    publishDate: { type: 'string' },
    claims: {
      type: 'array', maxItems: 5,
      items: {
        type: 'object', required: ['claim', 'quote', 'importance'],
        properties: {
          claim: { type: 'string' },
          quote: { type: 'string' },
          importance: { enum: ['central', 'supporting', 'tangential'] },
        },
      },
    },
  },
}
const VERDICT_SCHEMA = {
  type: 'object', required: ['verdict', 'evidence', 'confidence'],
  properties: {
    verdict: { enum: ['confirmed', 'unvalidated', 'refuted'] },
    evidence: { type: 'string' },
    confidence: { enum: ['high', 'medium', 'low'] },
    counterSource: { type: 'string' },
  },
}
const REPORT_SCHEMA = {
  type: 'object', required: ['summary', 'findings', 'caveats'],
  properties: {
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', required: ['claim', 'confidence', 'sources', 'evidence'],
        properties: {
          claim: { type: 'string' },
          confidence: { enum: ['high', 'medium', 'low'] },
          sources: { type: 'array', items: { type: 'string' } },
          evidence: { type: 'string' },
          vote: { type: 'string' },
        },
      },
    },
    leads: {
      type: 'array',
      items: {
        type: 'object', required: ['claim', 'sources', 'deficiency'],
        properties: {
          claim: { type: 'string' },
          sources: { type: 'array', items: { type: 'string' } },
          deficiency: { type: 'string' },
        },
      },
    },
    caveats: { type: 'string' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
}

log('Q: ' + QUESTION.slice(0, 80) + (QUESTION.length > 80 ? '…' : ''))
log(ANGLES.length + ' approved angles: ' + ANGLES.map(a => a.label).join(', ') +
  ' · maxFetch=' + MAX_FETCH + ' · centralVotes=' + CENTRAL_VOTES + ' · maxAppeals=' + MAX_APPEALS)

// ─── Dedup state ───
const normURL = u => {
  try {
    const p = new URL(u)
    return (p.hostname.replace(/^www\./, '') + p.pathname.replace(/\/$/, '')).toLowerCase()
  } catch { return u.toLowerCase() }
}
// arXiv PDF links frequently fail extraction; the /abs/ page (with ar5iv fallback)
// extracts reliably. Normalize before fetching (observed live: 3 arXiv PDFs → 0 claims).
const fetchableURL = u => u.replace(/arxiv\.org\/pdf\/(\d{4}\.\d{4,5})(v\d+)?/, 'arxiv.org/abs/$1')
const seen = new Map()
const dupes = []
const budgetDropped = []
const relRank = { high: 0, medium: 1, low: 2 }
let fetchSlots = MAX_FETCH

// ─── Three-way verdict rubric (shared by verifier, checker, appeal) ───
// Validated in the 2026-06-05 pilot: zero false "refuted", false kills recovered
// at the Sonnet tier. The vendor-doc line fixes the one observed systematic miss
// (product-capability claims drifting confirmed→unvalidated).
const VERDICT_RUBRIC =
  'Pick EXACTLY ONE verdict:\n' +
  '- **"confirmed"** — the source genuinely supports the claim as stated AND the source\'s quality/authority is adequate for what the claim asserts. Official vendor documentation IS adequate authority for claims about that vendor\'s own product capabilities (not for performance/scale/trust claims).\n' +
  '- **"unvalidated"** — the source genuinely says this and the claim restates it fairly, but the source\'s quality or independence is insufficient to treat it as established (vendor marketing, unreplicated preprint, promotional blog, no independent corroboration). Name the specific deficiency.\n' +
  '- **"refuted"** — affirmative evidence the claim is false, contradicted by the source or credible external evidence, or materially misleading as stated.\n' +
  '"unvalidated" is NOT a dumping ground for uncertainty — use it only after verifying what the source says. ' +
  'If the source cannot be fetched at all, use "unvalidated" and state that verification failed.\n'

// ─── Prompts ───
const SEARCH_PROMPT = (angle) =>
  '## Web Searcher: ' + angle.label + '\n\n' +
  'Research question: "' + QUESTION + '"\n\n' +
  'Your angle: **' + angle.label + '** — ' + (angle.rationale || '') + '\n' +
  'Search query: `' + angle.query + '`\n\n' +
  '## Task\nUse WebSearch with the query above. If the first pass yields weak, paywalled, or off-topic results, run ONE refined variant and merge. Return the top 4-6 most relevant results.\n' +
  'Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam/content farms and self-promotional preprints with extraordinary claims.\n' +
  'Prefer HTML/abstract pages over direct PDF links when both exist. Note the publication venue in the snippet when identifiable.\n' +
  'Include a short snippet capturing why each result is relevant.\n\nStructured output only.'

const FETCH_PROMPT = (source, angle) =>
  '## Source Extractor\n\n' +
  'Research question: "' + QUESTION + '"\n\n' +
  'Fetch and extract key claims from this source:\n' +
  '**URL:** ' + source.url + '\n**Title:** ' + source.title + '\n**Found via:** ' + angle + ' search\n\n' +
  '## Task\n1. Use WebFetch to retrieve the page content. For arXiv links prefer the /abs/ page; if the page truncates, try the ar5iv HTML version (ar5iv.labs.arxiv.org/html/<id>).\n' +
  '2. Assess source quality: primary research/institution? secondary reporting? blog/opinion? forum? unreliable?\n' +
  '3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim must:\n' +
  '   - be a concrete, checkable statement (not vague generalities)\n' +
  '   - include a direct quote from the source as support — VERBATIM where possible\n' +
  '   - PRESERVE the source\'s hedges and role attributions exactly ("may suffer" stays "may suffer"; a method used for selection must not be described as used for signal generation)\n' +
  '   - be rated central/supporting/tangential to the research question\n' +
  '4. Note publish date if available.\n\n' +
  'If the fetch fails or the page is irrelevant/paywalled, return claims: [] and sourceQuality: "unreliable".\n\nStructured output only.'

const VERIFY_PROMPT = (claim, v) =>
  '## Three-Way Claim Verifier (voter ' + (v + 1) + '/' + CENTRAL_VOTES + ')\n\n' +
  'Be SKEPTICAL but precise: ≥' + CENTRAL_KILL + '/' + CENTRAL_VOTES + ' "refuted" verdicts kill this claim; otherwise majority decides confirmed vs unvalidated.\n\n' +
  '## Research question\n' + QUESTION + '\n\n' +
  '## Claim under review\n"' + claim.claim + '"\n\n' +
  '**Source:** ' + claim.sourceUrl + ' (' + claim.sourceQuality + ')\n' +
  '**Supporting quote:** "' + claim.quote + '"\n\n' +
  '## Checklist\n' +
  '1. Verify against the SOURCE ITSELF (fetch it) — the supplied quote may be truncated or imperfectly extracted; judge the claim against the document, not the quote.\n' +
  '2. For arXiv sources: check the abstract page\'s Comments/journal-reference field for publication status BEFORE judging source quality — a journal-published paper is peer-reviewed primary evidence, not "just a preprint".\n' +
  '3. WebSearch for contradicting evidence — does any credible source dispute or heavily qualify this?\n' +
  '4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)\n' +
  '5. Is this marketing / a press release / a cherry-picked benchmark / forum speculation dressed up as fact?\n\n' +
  VERDICT_RUBRIC +
  '\nStructured output only. Evidence MUST be specific.'

const CHECK_PROMPT = (claim) =>
  '## Three-Way Quote-Support Checker (single vote — your verdict alone decides)\n\n' +
  '## Research question\n' + QUESTION + '\n\n' +
  '## Supporting claim under review\n"' + claim.claim + '"\n\n' +
  '**Source:** ' + claim.sourceUrl + ' (' + claim.sourceQuality + ')\n' +
  '**Supporting quote:** "' + claim.quote + '"\n\n' +
  '## Checklist (narrow — do NOT run broad web searches)\n' +
  '1. Fetch the source and verify the claim against the DOCUMENT — the supplied quote may be truncated, paraphrased, or internally inconsistent; refute only if the source itself fails to support the claim.\n' +
  '2. Does the source support the claim as stated, or is it an overreach/misread?\n' +
  '3. Is this marketing copy, a press release, or forum speculation dressed up as fact?\n\n' +
  VERDICT_RUBRIC +
  '\nStructured output only. Evidence MUST be specific.'

const APPEAL_PROMPT = (claim, tally) =>
  '## Appeal Verifier (final vote — overrides the panel only if you disagree with "refuted")\n\n' +
  'A verification panel voted ' + tally + ' to refute this claim from a primary source. Primary-source factual claims are sometimes killed on superficial grounds (missed publication status, judging the quote instead of the document). Re-examine from scratch.\n\n' +
  '## Research question\n' + QUESTION + '\n\n' +
  '## Claim under review\n"' + claim.claim + '"\n\n' +
  '**Source:** ' + claim.sourceUrl + ' (' + claim.sourceQuality + ')\n' +
  '**Supporting quote:** "' + claim.quote + '"\n\n' +
  '## Checklist\n' +
  '1. Fetch the source document itself and judge the claim against it, not the quote.\n' +
  '2. For arXiv sources: check Comments/journal-reference for publication status.\n' +
  '3. WebSearch for independent evidence either way.\n\n' +
  VERDICT_RUBRIC +
  '\nStructured output only. Evidence MUST be specific.'

// ─── Search (barrier) → fair selection → fetch+extract ───
// The barrier after Search is intentional: fair fetch-slot allocation across
// angles needs every angle's results first. The no-barrier pipeline version
// let the first angle to return consume the whole fetch budget (observed in
// the 2026-06-05 smoke run: 1 angle got all slots, 5 angles got zero).
phase('Search')
// seedResults: [{angle, results:[{url,title,snippet?,relevance}]}] found OUTSIDE the workflow (e.g. via
// WebFetch of the arXiv API when the per-process WebSearch cap is exhausted). Bypasses the searcher agents.
const SEED = Array.isArray(_a.seedResults) && _a.seedResults.length ? _a.seedResults : null
if (SEED) log('seedResults supplied for ' + SEED.length + ' angles — searcher agents SKIPPED')
const searchResults = SEED ? SEED.map(sr => ({ angle: sr.angle, results: [...sr.results].sort((a, b) => relRank[a.relevance] - relRank[b.relevance]) })) : (await parallel(
  ANGLES.map(angle => () => agent(SEARCH_PROMPT(angle), {
    label: 'search:' + angle.label, phase: 'Search', schema: SEARCH_SCHEMA, agentType: 'dr-searcher', model: 'sonnet',
  }).then(r => {
    if (!r) return null
    log(angle.label + ': ' + r.results.length + ' results')
    return { angle: angle.label, results: [...r.results].sort((a, b) => relRank[a.relevance] - relRank[b.relevance]) }
  }))
)).filter(Boolean)

// Dedup URLs (first angle that surfaced a URL keeps it), then interleave:
// each angle contributes its best remaining result in turn until the
// MAX_FETCH slots are filled, so no angle can starve the others.
const perAngle = searchResults.map(sr => ({
  angle: sr.angle,
  queue: sr.results.filter(r => {
    // Key on the fetchable form so an arXiv /pdf/ link from one angle and the
    // /abs/ page from another dedup to one source instead of burning two slots.
    const key = normURL(fetchableURL(r.url))
    if (seen.has(key)) {
      dupes.push({ ...r, angle: sr.angle, dupOf: seen.get(key) })
      return false
    }
    seen.set(key, { angle: sr.angle, title: r.title })
    return true
  }),
}))
const toFetch = []
while (fetchSlots > 0 && perAngle.some(a => a.queue.length > 0)) {
  for (const a of perAngle) {
    if (fetchSlots <= 0) break
    const src = a.queue.shift()
    if (!src) continue
    toFetch.push({ ...src, url: fetchableURL(src.url), angle: a.angle })
    fetchSlots--
  }
}
for (const a of perAngle) for (const r of a.queue) budgetDropped.push({ ...r, angle: a.angle })
log('Selected ' + toFetch.length + ' sources round-robin across ' + perAngle.length + ' angles' +
  (budgetDropped.length > 0 ? ' (' + budgetDropped.length + ' over budget)' : '') +
  (dupes.length > 0 ? ' (' + dupes.length + ' URL dupes)' : ''))

phase('Fetch')
const fetchedSources = await parallel(
  toFetch.map(source => () => {
    let host = 'unknown'
    try { host = new URL(source.url).hostname.replace(/^www\./, '') } catch {}
    return agent(FETCH_PROMPT(source, source.angle), {
      label: 'fetch:' + host,
      phase: 'Fetch',
      schema: EXTRACT_SCHEMA,
      agentType: 'dr-extractor',
      model: 'sonnet',
    }).then(ext => {
      // User-skip → null; drop it rather than mislabeling it "unreliable".
      if (!ext) return null
      if (ext.claims.length === 0) log('no claims: ' + source.url + ' (' + ext.sourceQuality + ')')
      return {
        url: source.url, title: source.title, angle: source.angle,
        sourceQuality: ext.sourceQuality, publishDate: ext.publishDate,
        claims: ext.claims.map(c => ({ ...c, sourceUrl: source.url, sourceQuality: ext.sourceQuality })),
      }
    }).catch(e => {
      log('fetch failed: ' + source.url + ' — ' + (e.message || e))
      return { url: source.url, title: source.title, angle: source.angle, sourceQuality: 'unreliable', claims: [] }
    })
  })
)

const allSources = fetchedSources.filter(Boolean)
const allClaims = allSources.flatMap(s => s.claims)

// ─── Rank + tier the claim pool ───
const impRank = { central: 0, supporting: 1, tangential: 2 }
const qualRank = { primary: 0, secondary: 1, blog: 2, forum: 3, unreliable: 4 }
const tangential = allClaims.filter(c => c.importance === 'tangential')
const verifiable = allClaims.filter(c => c.importance !== 'tangential')
const rankedClaims = [...verifiable]
  .sort((a, b) => (impRank[a.importance] - impRank[b.importance]) || (qualRank[a.sourceQuality] - qualRank[b.sourceQuality]))
  .slice(0, MAX_VERIFY_CLAIMS)
const overCap = verifiable.length - rankedClaims.length
if (tangential.length > 0) log('Dropped ' + tangential.length + ' tangential claims (not verified, not reported)')
if (overCap > 0) log('Claim cap: ' + overCap + ' verifiable claims beyond top ' + MAX_VERIFY_CLAIMS + ' dropped')
const nCentral = rankedClaims.filter(c => c.importance === 'central').length
log('Fetched ' + allSources.length + ' sources → ' + allClaims.length + ' claims → verifying ' + rankedClaims.length +
  ' (' + nCentral + ' central ×' + CENTRAL_VOTES + ' votes, ' + (rankedClaims.length - nCentral) + ' supporting ×1)')

if (rankedClaims.length === 0) {
  return {
    question: QUESTION,
    summary: 'No verifiable claims extracted. ' + allSources.length + ' sources fetched. ' +
      dupes.length + ' URL dupes, ' + budgetDropped.length + ' budget-dropped, ' + tangential.length + ' tangential-only.',
    findings: [], leads: [], refuted: [],
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality })),
    stats: { angles: ANGLES.length, sources: allSources.length, claims: allClaims.length, dupes: dupes.length },
  }
}

// ─── Verify: tiered three-way votes ───
// Barrier here is intentional — claim pool must be fully assembled before ranking/verification.
phase('Verify')
const tallyOf = c => c.confirmedVotes + '✓/' + c.unvalidatedVotes + '?/' + c.refutedVotes + '✗'
const voted = (await parallel(
  rankedClaims.map(claim => () => {
    const isCentral = claim.importance === 'central'
    const votes = isCentral ? CENTRAL_VOTES : 1
    const kill = isCentral ? CENTRAL_KILL : 1
    return parallel(
      Array.from({ length: votes }, (_, v) => () =>
        agent(isCentral ? VERIFY_PROMPT(claim, v) : CHECK_PROMPT(claim), {
          label: (isCentral ? 'v' : 'c') + v + ':' + claim.claim.slice(0, 40),
          phase: 'Verify',
          schema: VERDICT_SCHEMA,
          agentType: isCentral ? 'dr-verifier' : 'dr-checker',
          model: 'sonnet',
        })
      )
    ).then(verdicts => {
      // A vote can be null (user-skip or agent error) — treat as abstain.
      // A claim needs a quorum of valid votes to be adjudicated at all;
      // too many abstentions = unverified, which must NOT pass into the report.
      const valid = verdicts.filter(Boolean)
      const refutedVotes = valid.filter(v => v.verdict === 'refuted').length
      const confirmedVotes = valid.filter(v => v.verdict === 'confirmed').length
      const unvalidatedVotes = valid.filter(v => v.verdict === 'unvalidated').length
      const abstained = votes - valid.length
      let status
      if (valid.length < kill) status = 'unverified'
      else if (refutedVotes >= kill) status = 'refuted'
      else status = confirmedVotes > unvalidatedVotes ? 'confirmed' : 'unvalidated' // tie → conservative
      const c = { ...claim, verdicts: valid, refutedVotes, confirmedVotes, unvalidatedVotes, votesRequested: votes, status }
      log('"' + claim.claim.slice(0, 50) + '…": ' + tallyOf(c) +
        (abstained > 0 ? ' (' + abstained + ' abstain)' : '') + ' → ' + status)
      return c
    })
  })
)).filter(Boolean)

// ─── Appeal lane: refuted claims from primary sources get one Opus re-look ───
// Validated 2026-06-05: Sonnet false kills concentrated in primary-source factual
// claims (missed journal status, judged quote instead of document); Opus appeals
// overturned all sampled false kills and upheld every correct one.
const appealTargets = voted.filter(c => c.status === 'refuted' && c.sourceQuality === 'primary').slice(0, MAX_APPEALS)
if (appealTargets.length > 0) {
  log('Appeals: ' + appealTargets.length + ' refuted primary-source claim(s) → 1 Opus vote each')
  await parallel(appealTargets.map(c => () =>
    agent(APPEAL_PROMPT(c, tallyOf(c)), {
      label: 'appeal:' + c.claim.slice(0, 40),
      phase: 'Verify',
      schema: VERDICT_SCHEMA,
      agentType: 'dr-verifier',
      model: 'opus',
    }).then(v => {
      if (!v) return
      c.verdicts.push(v)
      c.appealed = true
      if (v.verdict !== 'refuted') {
        log('appeal OVERTURNED → ' + v.verdict + ': "' + c.claim.slice(0, 50) + '…"')
        c.status = v.verdict
        c.overturned = true
      } else {
        log('appeal upheld refuted: "' + c.claim.slice(0, 50) + '…"')
      }
    })
  ))
}

const confirmed = voted.filter(c => c.status === 'confirmed')
const leads = voted.filter(c => c.status === 'unvalidated')
const killed = voted.filter(c => c.status === 'refuted')
const unverified = voted.filter(c => c.status === 'unverified')
log('Verify done: ' + voted.length + ' claims → ' + confirmed.length + ' confirmed, ' +
  leads.length + ' unvalidated leads, ' + killed.length + ' refuted' +
  (unverified.length > 0 ? ', ' + unverified.length + ' unverified (abstentions)' : ''))

const refutedOut = killed.map(c => ({ claim: c.claim, tally: tallyOf(c), source: c.sourceUrl, appealed: !!c.appealed }))

if (confirmed.length === 0 && leads.length === 0) {
  return {
    question: QUESTION,
    summary: 'All ' + voted.length + ' claims refuted (or unverified) by three-way verification. Research inconclusive — sources may be low-quality or claims overstated.',
    findings: [], leads: [],
    refuted: refutedOut,
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: ANGLES.length, sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: 0, unvalidated: 0, killed: killed.length, unverified: unverified.length },
  }
}

// ─── Synthesize ───
phase('Synthesize')
const confRank = { high: 0, medium: 1, low: 2 }
const claimBlock = (c, i) => {
  const best = c.verdicts.filter(v => v.verdict === c.status).sort((a, b) => confRank[a.confidence] - confRank[b.confidence])[0]
    || c.verdicts[0]
  return '### [' + i + '] ' + c.claim + '\n' +
    'Tally: ' + tallyOf(c) + ' (' + c.importance + (c.appealed ? ', appealed' : '') + ') · Source: ' + c.sourceUrl + ' (' + c.sourceQuality + ')\n' +
    'Quote: "' + c.quote + '"\nVerifier evidence (' + (best ? best.confidence : '?') + '): ' + (best ? best.evidence : 'n/a') + '\n'
}
const confirmedBlock = confirmed.map((c, i) => claimBlock(c, i)).join('\n')
const leadsBlock = leads.length > 0
  ? '\n## Unvalidated leads (source genuinely says this, but quality/independence insufficient — report SEPARATELY from findings, never as established)\n' +
    leads.map((c, i) => claimBlock(c, confirmed.length + i)).join('\n')
  : ''
const killedBlock = killed.length > 0
  ? '\n## Refuted claims (for transparency)\n' +
    killed.map(c => '- "' + c.claim + '" (' + c.sourceUrl + ', tally ' + tallyOf(c) + ')').join('\n')
  : ''

const report = await agent(
  '## Synthesis: research report\n\n' +
  '**Grounding constraints:** ' + (TODAY ? 'Today\'s date is ' + TODAY + '. ' : '') +
  'Base every statement about a source\'s provenance, existence, or publication status STRICTLY on the verifier evidence supplied below. ' +
  'Do NOT assert that any source is fabricated, non-existent, future-dated, or suspect based on your own background knowledge or its date. ' +
  'If verifier evidence does not establish a source\'s provenance, omit provenance judgments entirely.\n\n' +
  '**Question:** ' + QUESTION + '\n\n' +
  confirmed.length + ' claims were CONFIRMED and ' + leads.length + ' are UNVALIDATED LEADS after three-way verification (' +
  CENTRAL_VOTES + '-vote with counter-search for central claims, single quote-check for supporting ones, Opus appeal for refuted primary-source claims). Merge semantic duplicates and synthesize.\n\n' +
  '## Confirmed claims\n' + confirmedBlock + leadsBlock + '\n' + killedBlock + '\n\n' +
  '## Instructions\n' +
  '1. Identify claims that say the same thing — merge them, combine their sources.\n' +
  '2. Group related CONFIRMED claims into coherent findings. Each finding should directly address the research question.\n' +
  '3. Put UNVALIDATED leads into the separate `leads` array (claim, sources, deficiency) — they are follow-up material, NOT findings; never blend them into findings or the summary as established facts.\n' +
  '4. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources, split votes, or single-vote supporting claims), low (single source or blog-quality).\n' +
  '5. Write a 3-5 sentence executive summary answering the research question from CONFIRMED findings only.\n' +
  '6. Note caveats: what’s uncertain, what sources were weak, what time-sensitivity applies.\n' +
  '7. List 2-4 open questions that emerged but weren’t answered.\n\nStructured output only.',
  { label: 'synthesize', phase: 'Synthesize', schema: REPORT_SCHEMA, agentType: SYNTH_TYPE }
)

const votesSpent = voted.reduce((n, c) => n + c.votesRequested, 0) + appealTargets.length
const agentCalls = ANGLES.length + allSources.length + votesSpent + 1

if (!report) {
  // Synthesis skipped/errored — salvage the verified claims raw rather
  // than throwing on report.findings and discarding the whole run.
  return {
    question: QUESTION,
    summary: 'Synthesis step was skipped or failed — returning ' + confirmed.length + ' confirmed claims and ' + leads.length + ' leads unmerged.',
    findings: [],
    confirmed: confirmed.map(c => ({ claim: c.claim, source: c.sourceUrl, quote: c.quote, tally: tallyOf(c) })),
    leads: leads.map(c => ({ claim: c.claim, sources: [c.sourceUrl], deficiency: (c.verdicts.find(v => v.verdict === 'unvalidated') || {}).evidence || '' })),
    refuted: refutedOut,
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: ANGLES.length, sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: confirmed.length, unvalidated: leads.length, killed: killed.length, afterSynthesis: 0, agentCalls },
  }
}

return {
  question: QUESTION,
  ...report,
  refuted: refutedOut,
  sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, angle: s.angle, claimCount: s.claims.length })),
  stats: {
    angles: ANGLES.length,
    sourcesFetched: allSources.length,
    claimsExtracted: allClaims.length,
    tangentialDropped: tangential.length,
    claimsVerified: voted.length,
    centralClaims: nCentral,
    confirmed: confirmed.length,
    unvalidated: leads.length,
    killed: killed.length,
    unverified: unverified.length,
    appeals: appealTargets.length,
    overturnedOnAppeal: voted.filter(c => c.overturned).length,
    afterSynthesis: report.findings.length,
    urlDupes: dupes.length,
    budgetDropped: budgetDropped.length,
    agentCalls,
  },
}
