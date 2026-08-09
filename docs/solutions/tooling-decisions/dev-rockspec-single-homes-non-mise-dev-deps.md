---
title: A dev-only rockspec single-homes dev dependencies mise cannot pin
date: 2026-08-08
category: tooling-decisions
module: ci-toolchain-setup
problem_type: config_drift
component: tooling
symptoms:
  - "The same dev dependency is named in both the justfile and .github/workflows/ci.yml, so a version or name change has to land in two places"
  - "mise.toml cannot pin the tool because mise's registry has no entry for it"
root_cause: duplicate_source_of_truth
resolution_type: config_change
severity: medium
tags:
  - luarocks
  - busted
  - mise
  - ci
---

## Problem

`busted` is the test runner, but mise's registry has `lua` and no `busted`, so it
cannot be pinned in `mise.toml` the way every other tool is. It was therefore
installed by a hardcoded `luarocks install --local busted` in **two** places: the
`justfile` `install` recipe and the CI workflow's install step.

Two independent declarations of one tool is the same shape as the failure in
[`ci-mise-toolchain-setup-failures.md`](../build-errors/ci-mise-toolchain-setup-failures.md),
where duplicate provisioning sources produced a CI-only break.

## Resolution

Declare the dependency once in a **dev-only rockspec** and have both callers read
it:

```lua
-- markua-pandoc-dev-1.rockspec
package = "markua-pandoc"
version = "dev-1"
source = { url = "git+https://github.com/unclesp1d3r/markua-pandoc.git" }
dependencies = { "lua >= 5.4", "busted >= 2.2, < 3.0", "luacheck >= 1.2, < 2.0" }
build = { type = "none" }
```

The pattern generalized: `luacheck` joined the same rockspec for the same reason —
a luarocks-only dev tool `mise.toml` cannot pin, which would otherwise be named in
both the justfile and the CI workflow.

`just install` runs `luarocks install --local --only-deps markua-pandoc-dev-1.rockspec`,
and CI's install step runs `just install`. The tool's name and version live in one
file.

## Why each field is what it is

- **`--only-deps`, not `--deps-only`.** Both work on luarocks 3.x, but `--only-deps`
  has existed since 2.2.2 while the alias only arrived in 3.4.0. Verified in
  luarocks' own source (`src/luarocks/cmd/build.lua` in the luarocks repository,
  not this one), which declares `cmd:flag("--only-deps --deps-only")`.
- **`build.type = "none"`.** The documented null build back-end. `build_rockspec()`
  checks and initializes `rockspec.build` and `rockspec.build.type` *before* it
  processes dependencies -- an absent type is defaulted to `"builtin"` there. Under
  `--only-deps` it then returns after dependency resolution and skips the build
  driver, which is the only place the type is acted on. So declaring `none` is what
  stops that `builtin` default from standing, and it makes a stray plain
  `luarocks make` an intentional no-op instead of module auto-discovery. The reader
  ships as a pandoc script, not an installable module.
- **`source.url` is mandatory but inert.** luarocks requires `package`, `version`, and
  `source.url` for the rockspec to parse, but `--only-deps` never fetches the source.
  It points at the repo for documentation value only.
- **`lua >= 5.4` is safe to declare.** luarocks injects `lua` as a virtual provided
  rock from the running interpreter and never tries to install it. CI confirms:
  `busted 2.3.0-1 depends on lua >= 5.1 (5.4-1 provided by VM: success)`.
- **Pin a version range.** An unconstrained `"busted"` lets a clean CI run resolve a
  newer release than any commit chose.

## What must not be touched

The PATH line after the install is load-bearing and unrelated to where the
dependency is declared:

```yaml
- name: Install dev dependencies
  run: |
    just install
    luarocks path --lr-bin | tr ':' '\n' >> "$GITHUB_PATH"
```

`luarocks path --lr-bin` returns a **colon-joined** string while `$GITHUB_PATH` takes
**one entry per line**, so dropping the `tr` silently takes the runner off PATH and
every later step fails to find it.

## Verification

Confirmed on a clean CI runner where busted was genuinely absent: luarocks resolved
it and its transitive dependencies from the rockspec, the PATH line registered the
bin directory, and `busted test/` then ran and passed. Repeat runs are safe —
`--only-deps` never registers the rock itself, so the "already installed, use --force"
short-circuit cannot fire.
