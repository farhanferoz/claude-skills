---
name: ground-before-summarizing
description: >-
  Before writing a RESUME/checkpoint entry or any state summary of research
  work, resolve state-claims and opaque short-hand labels (e.g. S2/S3/S4,
  H1/H2, method codenames) against source material via the corpus-search
  CLI (`corpus-search search-all "<query>"`) instead of restating them from
  memory. Use when
  about to summarize research findings, write or update a RESUME.md /
  CHANGELOG entry, or reference a jargon label that hasn't been spelled out
  in the current context.
---

# ground-before-summarizing

A state summary is only as good as its grounding. This skill closes the gap
between "I recall the conclusion" and "the source actually says this" —
the same failure mode the corpus-search tool exists to fix, applied to the
agent's own outputs.

## When this applies

- Writing or refreshing a `RESUME.md` / `CHANGELOG.md` entry for research work.
- Summarizing a session's findings, decisions, or open questions.
- About to write a short-hand label (`S2`, `S3`, `H1`, a method codename, an
  acronym coined earlier in the project) without spelling out what it means.

Skip this for purely mechanical work (code-only sessions, no research claims)
or when the corpus-search tool isn't set up on this machine (see below).

## Procedure

1. **Check the tool is available.** Run `command -v corpus-search` (on PATH in
   every cage) — bare `corpus-search` prints a help screen, which is ambiguous
   as an availability check. If the command is missing, say so once and fall
   back to normal summarizing; don't block on it. Searching through the CLI
   shares one warm daemon across every session — no per-project MCP
   registration is needed. The first search of a session may take ~30s while
   that shared daemon warms up; don't abort a first call just because it seems
   to hang — later calls in the same session return in ~1s.
2. **Before stating a claim as fact**, run
   `corpus-search search-all "<claim or label>"` (or
   `corpus-search query <repo> "<claim>"` to scope to one repo) via Bash. Read
   the returned passages (`file_path:heading` + snippet) — don't just trust that
   a hit exists; check the snippet actually supports the claim.
3. **Expand every opaque label** the first time it appears in the summary:
   write `S2 (per-timestep latent scale)` rather than bare `S2`, using the
   wording the source passage uses. This is the same rule as the standing
   "spell out terms on first use" preference, applied specifically to labels
   coined mid-project that don't carry meaning outside their source doc.
4. **If no passage supports a claim you were about to write**, don't state it
   as settled — mark it as unverified or drop it, the same as the
   verify-before-concluding discipline for any other analysis.
5. **Cite the source** inline where it's cheap to do so (`file_path:heading`),
   so a later reader (including a future you) can jump straight to it instead
   of re-deriving the claim from memory.

## Why

Opaque labels and unverified restatements compound across sessions — a label
coined once and repeated in five later summaries drifts from its source
meaning, and nobody notices because nothing points back to where it came
from. Grounding each claim at write-time is cheaper than untangling it later.
