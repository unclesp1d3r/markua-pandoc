---
title: Errors Module and Test Harness - Plan
type: feat
date: 2026-08-08
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Errors Module and Test Harness - Plan

## Goal Capsule

**Objective:** Ship Phase 1 Task 1 — the structured error type every later module raises through, the busted harness that runs it, and a dev rockspec that gives the busted dependency a single home.

**Authority hierarchy:** `docs/plan.md` Task 1 is the authoritative specification (per `AGENTS.md`); it already carries the intended source for both Lua files. GitHub issue #2 mirrors it and is subordinate. This plan governs execution order, the decisions `docs/plan.md` left open, and two explicit corrections to `docs/plan.md` itself: KTD5's `--only-deps` spelling and KTD7's directory-creation scope.

**Execution profile:** Test-driven. The spec is written and observed failing before `errors.lua` exists. Three units, dependency-ordered, landing as one commit.

**Stop conditions:** Stop and report rather than guessing if `errors.report`'s Strict/Lenient contract cannot be satisfied as specified, or if `luarocks --only-deps` cannot resolve busted from the rockspec.

**Tail ownership:** Caller owns commit, push, PR, and CI.

---

## Product Contract

### Summary

Add `src/markua/errors.lua`, a pure-Lua module raising structured errors that carry source position, plus the busted spec that proves it and a dev rockspec that declares busted once instead of twice.

### Problem Frame

Every later module in this reader reports unknown constructs by file and line. Without a shared error type they would each format their own message, and callers wanting the line number would parse strings to get it back. Separately, busted is currently named in two places — the `justfile` `install` recipe and the CI workflow's `Install busted` step — and this repo has already paid for duplicate tool-declaration sources in CI (`docs/solutions/build-errors/ci-mise-toolchain-setup-failures.md`).

### Requirements

#### Error type

- R1. `errors.new(file, line, message)` returns a table carrying `file`, `line`, and `message`.
- R2. `tostring()` on that table renders `file:line: message`. It coerces each field, so a nil or non-integer `line` renders literally instead of raising from inside the metamethod.
- R3. `errors.raise(file, line, message)` raises the table itself, so `pcall` yields an inspectable table rather than a string to parse.
- R4. `errors.warn(file, line, message, sink)` writes the rendered message and returns without aborting. `sink` defaults to stderr; passing one makes the output assertable.
- R5. `errors.report(cfg, file, line, message)` raises in Strict mode and warns, returning `false`, in Lenient mode. Strict is the default: `cfg` absent, or present without `strict = false`, raises.
- R6. The module is pure Lua and never references the `pandoc` global.

#### Test harness

- R7. `test/errors_spec.lua` exercises `new`, `raise`, both arms of `report`, and rendering with a nil `line`, and runs under busted from the repo root.
- R8. The spec is observed failing with `module 'src.markua.errors' not found` before `errors.lua` exists.

#### Dependency single-homing

- R9. busted is declared in exactly one place: `markua-pandoc-dev-1.rockspec`.
- R10. The `justfile` `install` recipe and the CI workflow both obtain busted through that rockspec.
- R11. CI keeps registering the luarocks bin directory on `$GITHUB_PATH` one entry per line.
- R12. The `justfile` defines no recipe whose script does not yet exist.

### Scope Boundaries

- `errors.lua` is the whole module surface for this task. The scanner, attribute parser, and config module are Tasks 2 onward.
- The rockspec declares dev dependencies only. Publishing this reader to luarocks.org is not in scope and depends on module-layout decisions this task does not make.
- `README.md` is Task 13's.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Raise a structured table, not a formatted string.** Callers inspect `.file` and `.line` directly instead of parsing a message back apart. `error(tbl, 0)` uses level 0 because Lua prepends position information only to string errors, and a table already carries its own. Governs R1, R3.
- KTD2. **Four-function surface including `report`.** (session-settled: user-approved — chosen over a two-function `new`/`raise` surface: `report` is the single place the Strict/Lenient choice is made, so the documented `--lenient` flag is a real switch rather than dead config for every later module.) Governs R4, R5.
- KTD3. **The dev rockspec is busted's single home.** (session-settled: user-approved — chosen over dropping the rockspec or writing a publishable distribution rockspec: it collapses the duplicate declaration in `justfile` and `ci.yml`, and the reader ships as a pandoc script rather than an installable luarocks module.) Governs R9, R10.
- KTD4. **mise owns the Lua toolchain.** (session-settled: user-directed — chosen over `brew install lua luarocks`: a Homebrew Lua stops matching the version CI and pandoc pin, so the interpreter under test diverges from the one that runs in production.) busted stays a luarocks package because mise's registry has `lua` but not `busted`.
- KTD5. **Use `--only-deps`, not its `--deps-only` alias.** `--only-deps` has existed since luarocks 2.2.2; `--deps-only` was added as an alias only in 3.4.0. The canonical spelling costs nothing and does not depend on the alias surviving.
- KTD6. **`build.type = "none"`.** The documented null build back-end. Under `--only-deps` luarocks returns straight after dependency resolution and never inspects `build`, so this only matters as a guard: a stray plain `luarocks make` becomes an intentional no-op instead of `builtin`'s module auto-discovery.
- KTD7. **Create only the directories that receive files in this task.** `docs/plan.md` Step 1 creates `src/markua`, `src/filters`, `bin`, and `test/golden`. Git does not track empty directories, so three of those four would not survive a clone. Create `src/markua/` and `test/` only; Tasks 9-12 create theirs alongside their first file.
- KTD9. **`warn` takes an optional sink.** Hardcoding `io.stderr` left R4's "writes the rendered message" unassertable without swapping a global, and a mutation test proved the Lenient-path scenario passed with the `warn` call deleted entirely. An optional trailing parameter keeps KTD2's four-function surface intact, removes the monkeypatch and its luacheck suppression from the spec, and is the seam a later caller would use to batch or cap a noisy full-book run. Governs R4.
- KTD8. **`__tostring` coerces with `%s`, not `%d`.** `docs/plan.md:147-149` uses `string.format("%s:%d: %s", ...)`. Verified in Lua 5.4: a nil `line` raises `bad argument #3 to 'string.format' (number expected, got nil)` and a float raises `number has no integer representation` — a secondary error thrown from inside the metamethod, which masks the original message rather than reporting it. Task 12's CLI-level errors (unreadable input file, unsupported output format) have no natural line number, so nil is a real input rather than a hypothetical. Use `%s` with `tostring()` on each field. `tostring(42)` is `"42"`, so R2's rendering is byte-identical for well-formed input. Governs R2.

### Strict and Lenient resolution

`report` collapses every `cfg` shape into two behaviors. The `type(cfg) == "table"`
check is load-bearing: a nil `cfg` would raise a nil-index error and a scalar one
would raise `attempt to index a number value` — from inside the module, masking
the error it was called to report.

| `cfg` argument | `cfg.strict` | Mode | Behavior |
| --- | --- | --- | --- |
| absent / `nil` | n/a | Strict | Raises |
| a scalar (e.g. `5`, `true`) | n/a | Strict | Raises |
| `{}` | `nil` | Strict | Raises |
| `{ strict = true }` | `true` | Strict | Raises |
| `{ strict = false }` | `false` | Lenient | Warns, returns `false` |

Strict is the default in three of the four shapes, matching the posture
`CONCEPTS.md` names. Only an explicit `strict = false` opts into Lenient.

### Assumptions

- `.busted` declares the spec root and module search path, so the contract is stated rather than implied. `just unit` runs from the justfile's directory and therefore works from any subdirectory; a bare `busted <path>` invoked from elsewhere is not a supported entry point.
- `lua >= 5.4` in `dependencies` is satisfied by the running interpreter — luarocks injects `lua` as a virtual provided rock from `cfg.lua_version` and never attempts to install it.
- Repeat CI runs are safe. `--only-deps` never registers the rock as installed, so the "already installed, use --force" short-circuit cannot fire on a second run.
- Confirmed on CI, not just locally: on a clean runner with busted genuinely absent, luarocks resolved it and its transitive dependencies from the rockspec against mise's Lua 5.4.8, reporting `lua >= 5.1 (5.4-1 provided by VM: success)`.

### Risks

- CI calls `luarocks path --lr-bin` without `--local` while installing with `--local`. Confirmed working end-to-end on a clean runner: the install resolved busted from the rockspec and `busted test/` then ran and passed. The PATH line is unchanged and must stay that way -- `--lr-bin` is colon-joined while `$GITHUB_PATH` takes one entry per line.
- `just lint` does not run luacheck. `.pre-commit-config.yaml` has no luacheck hook — luacheck runs on pull requests via CodeRabbit (`.luacheckrc:5`, `.coderabbit.yml`). Treat `just lint` as a formatting and workflow gate, and run luacheck directly to check the Lua.

---

## Implementation Units

### U1. Source tree and the failing errors spec

**Goal:** Stand up the directory skeleton and a spec that fails for the right reason.

**Requirements:** R7, R8

**Dependencies:** none

**Files:**

- `src/markua/` (create directory)
- `test/errors_spec.lua` (create)

**Approach:**

1. Create `src/markua/` and `test/`. Per KTD7, do not create `src/filters/`, `bin/`, or `test/golden/` — git will not track them empty.
2. Write `test/errors_spec.lua` from `docs/plan.md:104-134`.
3. Run it and confirm it fails because the module is missing.

**Patterns to follow:** `.luacheckrc:34-37` gives `test/*_spec.lua` the `lua54+busted` std, so busted's DSL is recognized.

**Execution note:** This unit is done when the spec fails with the module-not-found message. A failure with any other message means the spec is broken, not the missing module — fix the spec before moving on.

**Test scenarios:** The spec is this unit's artifact. It defines eight:

1. `errors.new("chapter-01.md", 42, "unknown attribute")` — `tostring` renders exactly `chapter-01.md:42: unknown attribute`.
2. `pcall(errors.raise, "a.md", 7, "boom")` — returns `false`, and the error value is a table with `.file == "a.md"`, `.line == 7`, `.message == "boom"`. Assert on the table fields, not on a rendered string; this is what distinguishes a structured raise from a string one.
3. `pcall(errors.report, { strict = true }, "a.md", 1, "boom")` — returns `false`, and the raised value is the structured error, not a bare string.
4. `pcall(errors.report, { strict = false }, "a.md", 1, "boom")` — returns `true`, the returned value is `false`, and the exact text `warn` wrote to stderr is asserted.
5. `tostring(errors.new("a.md", nil, "boom"))` — renders `a.md:nil: boom` rather than raising. Per KTD8 this is the guard against a `%d` format crash masking the real error.
6. `tostring(errors.new("a.md", 3.5, "boom"))` — renders `a.md:3.5: boom`. The other half of the `%d` hazard, which rejects a float with `number has no integer representation`.
7. `pcall(errors.report, nil, ...)` and `pcall(errors.report, {}, ...)` — both raise. Strict is the default for an absent or empty config.
8. `pcall(errors.report, 5, ...)` — raises the structured error, not `attempt to index a number value`. A scalar config must not fault inside the module.

**Verification:** `busted test/errors_spec.lua` exits non-zero and names `module 'src.markua.errors' not found`.

---

### U2. Implement the errors module

**Goal:** Take the spec from red to green with the minimum module that satisfies it.

**Requirements:** R1, R2, R3, R4, R5, R6

**Dependencies:** U1

**Files:**

- `src/markua/errors.lua` (create)
- `test/errors_spec.lua` (run, unchanged)

**Approach:** Implement per `docs/plan.md:144-183` — a module table, one shared metatable carrying `__tostring`, and the four functions. `report` branches on `type(cfg) == "table" and cfg.strict == false` so that a nil, empty, or scalar `cfg` all take the Strict path, which is the default posture named in `CONCEPTS.md`.

**Patterns to follow:** `.luacheckrc:16` declares no globals for `src/markua/*.lua` on purpose, so any `pandoc` reference is reported. The module uses only `setmetatable`, `string.format`, `error`, and `io.stderr:write` — all stock `lua54`.

**Test scenarios:** The eight from U1 now pass. Scenario 4 asserts the exact text `warn` writes by swapping `io.stderr` for the duration of the call, so the Lenient path is proven to warn rather than merely to return `false`.

**Verification:**

- `busted test/errors_spec.lua` reports 8 successes, 0 failures.
- `luacheck src/markua/errors.lua test/errors_spec.lua` reports zero warnings.

---

### U3. Single-home the busted dependency

**Goal:** Declare busted once in the rockspec and have both the justfile and CI read it from there.

**Requirements:** R9, R10, R11, R12

**Dependencies:** U2

**Files:**

- `markua-pandoc-dev-1.rockspec` (create)
- `justfile` (modify — `install` recipe)
- `.github/workflows/ci.yml` (modify — `Install busted` step body only)
- `docs/plan.md` (modify — four `--deps-only` occurrences, at lines 214, 233, 254 and 271; correct all of them to `--only-deps` per KTD5)

**Approach:**

1. Write the rockspec from `docs/plan.md:238-260`, with `--only-deps` as the documented invocation. `package`, `version`, and `source.url` are mandatory for the file to parse; `source.url` is never fetched under `--only-deps`, so it points at the repo for documentation value only.
2. Change the `justfile` `install` recipe to `luarocks install --local --only-deps markua-pandoc-dev-1.rockspec`.
3. In CI's `Install busted` step, replace only the `luarocks install --local busted` line with `just install`. Leave the `luarocks path --lr-bin | tr ':' '\n' >> "$GITHUB_PATH"` line below it unchanged — `--lr-bin` returns a colon-joined string and `$GITHUB_PATH` needs one entry per line, so that `tr` is load-bearing and unrelated to where busted is declared. The step keeps both lines; only the first changes.
4. Correct every `--deps-only` occurrence in `docs/plan.md` — Step 7's justfile snippet, Step 8's prose, the rockspec comment, and Step 8's justfile snippet. Correcting only one leaves that file self-inconsistent. Issue #2's acceptance list carries the same wording and now also a stale success count (it says 4; KTD8 adds a fifth scenario); check and update both alongside.

**Patterns to follow:** `docs/solutions/build-errors/ci-mise-toolchain-setup-failures.md` — do not add a per-tool GitHub Actions step for anything `mise.toml` already declares, and do not move busted into mise (its registry has no busted rock).

**Test expectation:** none — build configuration with no runtime behavior. Correctness is proven by the verification below rather than by unit tests.

**Verification:**

- `luarocks install --local --only-deps markua-pandoc-dev-1.rockspec` exits 0.
- `just install` exits 0 and resolves busted.
- `just unit` still reports 8 successes, proving busted is still reachable after the rewiring.
- Searching `justfile` and `.github/workflows/ci.yml` for `busted` finds it named as a dependency only in the rockspec.
- `just lint` passes, including actionlint on the modified workflow and markdownlint on the modified `docs/plan.md`.
- `just` with no arguments lists the recipes and none reference a script that does not exist.

---

## Verification Contract

| Gate | Command | Applies to | Done signal |
| --- | --- | --- | --- |
| Unit specs (red) | `busted test/errors_spec.lua` | U1 | Non-zero exit naming `module 'src.markua.errors' not found` |
| Unit specs (green) | `just unit` | U2, U3 | 8 successes, 0 failures |
| Lua lint | `luacheck src/markua/errors.lua test/errors_spec.lua` | U2 | Zero warnings. Run directly — `just lint` does not include luacheck |
| Repo hooks | `just lint` | U3 | actionlint, check-yaml, markdownlint, whitespace and EOF hooks all pass |
| Dependency install | `just install` | U3 | Exit 0 |
| Recipe list | `just` | U3 | Recipes listed; none call a missing script |

`busted` and `luacheck` live at `~/.luarocks/bin` and need `export PATH="$HOME/.luarocks/bin:$PATH"`. Lua itself comes from mise (5.4.8).

---

## Definition of Done

### Global

- All six Verification Contract gates pass.
- busted appears as a declared dependency in exactly one file.
- No module under `src/markua/` references the `pandoc` global.
- No exploratory or dead-end code remains in the diff.

### Per unit

- U1 — the spec exists and was observed failing for the module-not-found reason specifically.
- U2 — `errors.lua` exists, the eight scenarios pass, luacheck is clean.
- U3 — the rockspec exists, `justfile` and `ci.yml` both read from it, the `$GITHUB_PATH` line is unchanged, and `docs/plan.md` no longer says `--deps-only`.
