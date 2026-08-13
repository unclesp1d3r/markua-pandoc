# Residual Review Findings — Task 4: Reader config and class validation

Branch: `5-task-4-reader-config-with-overridable-callout-classes`
Plan: [`docs/plans/2026-08-10-001-feat-reader-config-and-class-validation-plan.md`](../plans/2026-08-10-001-feat-reader-config-and-class-validation-plan.md)

Every actionable P0/P1/P2 finding from the plan review and the code review was
applied on this branch. No tracker tickets were filed: the repo's open issues
track plan tasks, and these items are notes for future tasks rather than work
items of their own. This file is the durable record.

## Carried forward

- **P3 — `table.sort` in `validate` cannot be fully pinned by an in-process test.**
  The sort makes a multi-problem config report the alphabetically first key every
  run. Deleting it still passes the suite, because `pairs` order is stable within
  one Lua state — the seed only varies across processes. The test now uses eight
  keys and asserts the alphabetically first is named, which narrows the gap and
  never flakes on correct code, and the test comment states the limitation
  outright. Closing it properly would need a multi-process harness.
  *Source: testing reviewer, advisory.*

- **Error-convention split between `config` and `errors`.**
  `config.load_file` returns `nil, message`, so a bad `--config` file surfaces as
  a bare string. Every other reader error goes through `errors.raise`, whose
  `__tostring` renders `file:line: message`. The config message is still
  actionable — it embeds the path, and Lua's own syntax errors carry a line — but
  the shapes differ. Whoever lands Task 9's `Reader()` should decide whether the
  reader wants one uniform author-facing error shape.
  *Source: reliability reviewer, residual risk (out of that persona's finding scope).*

- **No CPU or wall-clock bound on a config chunk.**
  `loadfile(path, "t", {})` denies every library, but `while true do end` needs no
  globals and hangs the conversion with no diagnostic. Same class as the
  memory-exhaustion vector already recorded in the plan's Risks section, and
  accepted on the same premise: the file is the author's own. A `debug.sethook`
  count hook around the `pcall` is the mitigation if that premise ever stops
  holding.
  *Source: security and reliability reviewers, residual risk. Deliberately deferred — see the plan's Risks.*

- **The string library is reachable inside the sandbox via literal method syntax.**
  `("A"):rep(n)` works even though the `string` global is nil, because the string
  metatable binds at the VM level rather than through `_ENV`. There is no path
  back to `os`/`io` from it; it is a cheaper allocation vector than the loop the
  plan's Risks section already describes, not a new capability.
  *Source: security reviewer, residual risk.*

- **The TDD claim is not provable from the git log alone.**
  Each unit's commit bundles its test and implementation, so the red step is not
  visible as a separate commit. It did happen — each unit was run red before
  implementing, and the transcript records the failures — but a reader auditing
  only the history cannot confirm it. Separate red commits would be the fix, at
  the cost of a history with deliberately failing commits in it.
  *Source: adversarial and project-standards reviewers, residual risk.*

- **The single-channel config-key pattern is not captured in `docs/solutions/`.**
  `REDIRECTED_KEYS` rejects `strict` from a config file and points the author at
  `--lenient`, because `Reader()` applies the flag before merging the file and a
  shallow replace would silently cancel it. That reasoning currently lives only
  in the plan's KTD7. The next contributor adding a config key that collides with
  a CLI flag will not find it by searching `docs/solutions/`.
  *Source: learnings researcher, advisory. The higher-value lesson from this branch — that `#` and `ipairs` cannot validate a Lua array — was captured instead, at `docs/solutions/design-patterns/lua-array-validation-cannot-trust-length.md`.*

- **Nothing enforces R15's byte-identity, and it broke once during this branch.**
  `docs/plan.md` Task 4 embeds both shipped files verbatim, but no CI job, `just`
  recipe, or pre-commit hook verifies it. On this branch a late one-line comment
  fix to `src/markua/config.lua` landed without the matching re-sync and had to be
  repaired in a follow-up commit — one break in eight commits, caught only because
  the check was run by hand. A ~20-line extraction script wired into `just test`
  would turn R15 into a real gate. Not built here: it changes `just`/CI, a shared
  surface outside Task 4's scope, and belongs with the Task 9 golden-file harness
  that `docs/plan.md` already plans.
  *Source: this branch's own history.*

## Refuted during review

- The adversarial reviewer claimed to have "proved structurally" that no table
  with a hole can make `#` equal its `pairs` count, contradicting the correctness
  reviewer's bypass report. Running the specific input settled it: `pairs` count
  6, `#t` 6, `ipairs` yielding nothing. The correctness reviewer was right and the
  finding was fixed.
