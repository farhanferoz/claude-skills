# Coding standards (every project)

The one statement of how code is written; loaded at launch in every project. Project files never restate it; they
add only project facts (linter settings, type aliases, layout). Reasons: `~/.claude/rule-history.md`. Exploratory
analysis may skip 1, 2 and 7.

1. **Reuse before writing.** Search the repository first and name what you searched; stop at the first rung that
   holds: not needed, in the codebase, stdlib, platform feature, installed dependency, one line, the minimum.
   Wrap, never reimplement (above all metrics and kernels); a second copy is centralised. Refactors are verbatim
   moves. Reusable code lives in tracked, tested modules; scripts stay thin. Never cut validation, data-loss
   handling, security or accessibility to save code.
2. **Design.** One responsibility per class and function; shared contracts as a `Protocol` or base class;
   composition before inheritance; records as frozen dataclasses; no mutable module state. A growing branch on
   cases means the interface is wrong: fix the interface, not add the branch.
3. **Configurable, never hard-coded.** Anything a run, study or job might change (optimizer, schedule, stopping,
   thresholds, grids, budgets, seeds, packing, paths) is chosen by name from a config: a preset in its group, a
   tracked settings file, or a CLI flag defaulting to today's value. Never a module constant or an override string
   written in by code. A new model, system or variant is a config change; code never branches on their names.
   Constants left in code are facts (a file format, a mathematical minimum), each commented as such.
4. **Types.** Closed sets are an `Enum`/`StrEnum`/`Literal`, compared as that type, never as strings (ruff
   `PLR2004` is fed back on every Python edit). Every new function is fully typed: Python type hints; TypeScript
   never `any`, with an interface for each API response.
5. **Errors.** Source raises explicit exceptions naming the remedy, never prints its own bypass; `assert` is for
   tests only.
6. **Performance and memory.** Vectorise: no Python loops over batch, members, leads, channels or sites (justify
   any that stay). Size peak memory from the shapes and dtypes the code builds before running on real data, and
   request that; float64 only where needed; no needless copies; chunk large arrays. An out-of-memory kill is a
   design defect.
7. **Tests.** One test per behaviour that can break, not per helper; fold a new check into an existing test, cut
   duplicates and tests that cannot fail (never trust-boundary, data-loss or security tests); a commit adding tests
   says why (`Tests: +N, <defect caught>`). Mutation-check new tests. Run only the change's own tests, once; any
   check runs in seconds, never over 3-4 minutes, else cut it down; a whole suite runs in minutes, slow tests
   opt-in. Enforced by `~/.claude/pytest_budget` (one broad run per session and checkout, 240 s cap). A gate (test,
   lint, typecheck, build) must be able to fail: run it as its own command, never piped into `tail` or similar, and
   see it red once before trusting it. A plan lists each permanent test with its edge cases, keeps one-off release
   checks apart from permanent tests, and says what is deliberately not tested.
8. **Style.** The project's linter and formatter settings are the source of truth, in its config, not in prose.
9. **Briefs and reviews.** Every brief states 1-3 as primary constraints and asks what was reused and which
   constants stayed. Every diff review (a worker's or one's own) checks 1-7 and removes unjustified constants in
   the same review.
