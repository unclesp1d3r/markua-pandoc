---
title: CI toolchain setup fails when per-tool actions duplicate mise
date: 2026-08-08
category: build-errors
module: ci-toolchain-setup
problem_type: build_error
component: tooling
symptoms:
  - "CI's test job fails during toolchain setup, before any busted spec or golden file runs"
  - "The leafo/gh-actions-luarocks step fails running `configure --with-lua=./.lua`, a directory only its removed companion step (leafo/gh-actions-lua) creates"
  - "jdx/mise-action's `--locked` install fails because luajit has no linux-x64 entry in mise.lock, and `mise lock --platform linux-x64` cannot add one"
root_cause: config_error
resolution_type: config_change
severity: high
related_components:
  - development_workflow
tags:
  - ci
  - mise
  - github-actions
  - toolchain
  - luajit
  - mise-lock
---

# CI toolchain setup fails when per-tool actions duplicate mise

## Problem

On the `chore/repo-bootstrap` branch (PR #1, open against `main` as of this
writing — <https://github.com/unclesp1d3r/markua-pandoc/pull/1>), CI's `test`
job failed during toolchain setup, before a single busted spec or golden file
ran. Two independent root causes had to be diagnosed and fixed separately:
a per-tool GitHub Actions step that conflicted with `mise`, and a `mise.lock`
gap that `mise-action`'s `--locked` install mode cannot tolerate.

## Symptoms

- The `Set up LuaRocks` step (`leafo/gh-actions-luarocks@v6`) failed outright.
- `extractions/setup-just` and a hand-rolled pandoc `.deb` install ran
  alongside `jdx/mise-action`, each installing a tool `mise.toml` already
  pinned — a second, silently-possible source of version drift between CI and
  local dev rather than a visible failure.
- Separately, `jdx/mise-action` failed at the tool-install step because
  `mise.lock` had no `linux-x64` entry for `luajit` — `mise-action` installs
  with `--locked`, so a missing platform entry for any declared tool fails
  setup for the whole job.

## What Didn't Work

- Removing only the `leafo/gh-actions-lua` companion step while leaving
  `leafo/gh-actions-luarocks@v6` in place. `leafo/gh-actions-luarocks` runs
  `configure --with-lua=./.lua`, and `./.lua` is a directory only
  `leafo/gh-actions-lua` creates — per the commit message for `fddfa2b` ("fix(ci): let mise own the
  toolchain"), once
  that companion step was gone, this step could never succeed. This was
  diagnosed from the actual failed-job log (`gh run view --log-failed`)
  rather than guessed. (session history)
- Running `mise lock` to regenerate `mise.lock` and pick up a `linux-x64`
  entry for `luajit` — mise's own suggested remediation, and the first thing
  tried. It did not work: after the regeneration, `mise.lock` still had only
  `macos-arm64` and `windows-x64` entries under `luajit`, confirmed by
  parsing the file for a `linux-x64` platform section and finding none.
  (session history) Per the commit message for `ec76d6c` ("fix(ci): drop
  luajit, which cannot be locked for linux"),
  `mise lock --platform linux-x64` silently *skips* `conda:luajit` for that
  platform rather than erroring — so the gap is invisible locally until
  `mise-action`'s `--locked` install fails in CI. There is no lockfile-side
  fix; the tool has to come out of `mise.toml`.
- Pinning `pandoc = "latest"` in `mise.toml` (commit `832f503`, "chore:
  update pandoc version to latest in mise.toml") to chase the newest release.
  This was pinned back five commits later in `11ce31f` ("chore: pin pandoc
  version to 3.10.1 in mise.toml") to the exact version
  `pandoc = "3.10.1"` (`mise.toml:7`) — `latest` reintroduces the same
  local/CI drift risk that pinning was supposed to eliminate, for a tool the
  custom reader API has a hard minimum-version requirement on.

## Solution

**Fix 1 — stop double-provisioning tools `mise.toml` already owns (commit
`fddfa2b`, "fix(ci): let mise own the toolchain").** `.github/workflows/ci.yml`
dropped `leafo/gh-actions-luarocks`, `extractions/setup-just`, and the
`PANDOC_VERSION` env var, replacing them with one step that verifies every
tool mise provisioned and asserts the pandoc floor. (The hand-rolled pandoc
`.deb` install had already come out of the workflow two commits earlier, in
`a191961`, "ci: add CodeRabbit and luacheck configuration", which dropped it
alongside the Lua 5.4/5.5 matrix — so `fddfa2b` itself did not remove it.)

```yaml
# .github/workflows/ci.yml:39-50 (current)
      # mise supplies lua, luarocks (bundled with the lua plugin), just and
      # pandoc. Fail here with a readable message rather than in a later step.
      # leafo/gh-actions-luarocks is deliberately absent: it configures against
      # a ./.lua directory that only leafo/gh-actions-lua creates.
      - name: Verify toolchain
        run: |
          lua -v
          luarocks --version | head -1
          just --version
          pandoc --version | head -1
          pandoc --version | head -1 | awk '{split($2, v, "."); if (v[1] < 3 || (v[1] == 3 && v[2] < 10))
            { print "pandoc " $2 " is too old; the custom reader API needs 3.10+"; exit 1 }}'
```

Before deleting anything, the redundancy was verified empirically rather than
assumed: `mise x -- which luarocks` resolves inside mise's own Lua install,
and the mise step's CI log shows its Lua plugin already building
`luarocks 3.13.0-1`. (session history)

`busted` stays a separate install (`.github/workflows/ci.yml:54-57`) because
it is a luarocks rock, not a tool `mise.toml` can pin — mise's registry has
`lua` but neither `busted` nor a standalone `luarocks`:

```yaml
      - name: Install busted
        run: |
          luarocks install --local busted
          luarocks path --lr-bin | tr ':' '\n' >> "$GITHUB_PATH"
```

The `tr ':' '\n'` is not incidental: `luarocks path --lr-bin` returns a
colon-joined string, and `$GITHUB_PATH` takes one entry per line.
(session history)

**Fix 2 — drop `luajit` from `mise.toml` rather than work around the lock gap
(commit `ec76d6c`).** Removed with `mise use --rm luajit`, not by hand-editing
the file (session history):

```diff
 [tools]
 just                = "latest"
 lua                 = "5.4.8"
 pandoc              = "latest"
 shellcheck          = "latest"
 "pipx:pre-commit"   = "latest"
 lua-language-server = "3.18.2"
-luajit              = "2.1.1744318430"
```

(`pandoc` still reads `"latest"` in that diff because the pin back to
`3.10.1` landed later, in `11ce31f`.)

`mise.toml:4-10` today has no `luajit` line. Note that `mise.lock` still
carries a stale `[[tools.luajit]]` block with `macos-arm64` and `windows-x64`
platform entries (`mise.lock:70-90`) — it was never regenerated after the
tool was dropped from `mise.toml`. This is harmless (mise only installs what
`mise.toml` declares), but it is a loose end: running `mise lock` again would
clean it up.

After both fixes, CI went green and local/CI parity was confirmed by
comparing versions on both sides: `just 1.58.0`, Lua `5.4.8`,
luarocks `3.13.0`, pandoc `3.10.1`. (session history)

A related, smaller fix worth citing as evidence for the same "hand-rolled
installers cost more than they look like they will" pattern: commit
`7ff2b17` had to change the pre-`mise` pandoc `.deb` bootstrap in
`CONTRIBUTING.md` from a hardcoded `amd64` URL to one selected by
`dpkg --print-architecture`, because the original hardcoded value broke on
arm64 hosts.

## Why This Works

Both fixes remove a source of truth CI was accidentally maintaining in
parallel with `mise.toml`/`mise.lock`:

- `jdx/mise-action` (`.github/workflows/ci.yml:32-37`) is now the only
  provisioning step. Per `AGENTS.md:56-60`, `mise.toml` pins versions and
  `mise.lock` pins the resolved artifacts so local dev and CI resolve
  identically; every per-tool GitHub Action (`leafo/gh-actions-luarocks`,
  `extractions/setup-just`, the manual pandoc `.deb`) was a second,
  independently-versioned path to the same tool, which is exactly the
  condition under which CI and a contributor's machine can silently disagree
  on which pandoc or which `just` actually ran the suite.
- The `Verify toolchain` step turns a missing-or-wrong-tool problem into a
  readable failure at the first CI step, rather than three steps later as an
  opaque busted or golden-file failure with no indication the toolchain
  itself was the culprit.
- Dropping `luajit` removes a tool the project does not actually use for
  anything load-bearing. Per `AGENTS.md:62-65`, pandoc embeds Lua 5.4, and
  that is the interpreter that executes the reader in production (the
  `ec76d6c` commit message is where the sharper "PUC Lua 5.4" phrasing comes
  from); busted
  also runs under Lua 5.4 per the `test (lua 5.4)` job name
  (`.github/workflows/ci.yml:19`). LuaJIT is Lua 5.1-compatible — running
  specs under it would disagree with production Lua 5.4 on integer division,
  `goto`, and the integer/float distinction (per the `ec76d6c` commit
  message), so it was a dev tool that could only produce false confidence or
  false failures relative to what actually ships. Keeping a tool that cannot
  be locked for the CI platform, purely because it might be useful someday,
  was strictly worse than removing it.

The same "test the interpreter that actually ships" reasoning had already
retired a Lua 5.5 matrix leg earlier in the branch: checking
`pandoc lua -e 'print(_VERSION)'` against pandoc 3.10.1 showed 5.4, so the
5.5 leg was testing a runtime the code never executes. (session history)

## Prevention

- **Do not add a per-tool GitHub Actions setup step for anything
  `mise.toml` already declares.** If a workflow step installs a tool by name
  (`setup-just`, `setup-lua`, a hand-rolled `curl`/`dpkg` install), check
  `mise.toml` first — `jdx/mise-action` already provisions it, and a second
  installer is not redundancy-as-safety, it is two version sources that can
  disagree. (auto memory [claude]: "mise is the toolchain source of truth" —
  CI uses `jdx/mise-action` and nothing else for provisioning; do not add a
  per-tool setup action for anything `mise.toml` already declares.)
- **After removing or changing a tool in `mise.toml`, run
  `mise lock --platform linux-x64` and check the diff, not just that the
  command exited zero.** `mise lock` can silently skip a tool/platform
  combination it cannot resolve (as it did for `conda:luajit` on
  `linux-x64`) instead of erroring — the failure only surfaces later, in CI,
  as an opaque `--locked` install failure. A clean `mise lock` run is not
  proof every declared tool actually has a Linux entry; grep the regenerated
  `mise.lock` for the tool name and confirm a `platforms.linux-x64` section
  exists. The same applies in the removal direction: `ec76d6c` changed
  `mise.toml` only, which is why the orphaned `[[tools.luajit]]` block noted
  above is still sitting in `mise.lock`.
- **Prefer removing an unused, hard-to-lock dev tool over working around the
  lock gap.** Before adding a workaround (vendoring a build, pinning an
  older version, hand-rolling a linux-x64 install), ask whether the tool is
  actually load-bearing. Here it was not: nothing in the reader or its tests
  runs under LuaJIT, and running specs under a Lua dialect the production
  interpreter (pandoc's embedded PUC Lua 5.4) doesn't share was a liability,
  not a convenience.
- **Change `mise.toml` via `mise use <tool>@<version>` (or `mise use --rm`),
  never by hand.** (auto memory [claude]: "Prefer tool CLI over hand-editing
  config" — a hand-edit during this same work produced a duplicate `lua` key
  that made the TOML invalid and broke every `mise` invocation until
  repaired.) Follow every `mise use` with `mise lock --platform linux-x64` so
  CI's `--locked` install stays resolvable — per `AGENTS.md:58-60`, this is a
  required pair, not two independent steps.
- **A version pinned as `"latest"` in `mise.toml` is not free of drift
  risk for tools with a hard minimum-version requirement.** `pandoc` was
  briefly set to `"latest"` (`832f503`) before being pinned back to
  `"3.10.1"` (`11ce31f`, `mise.toml:7`) specifically because the custom
  reader API needs 3.10+ and nothing enforces that floor when the version
  string floats. The `Verify toolchain` step's `awk` guard is the backstop,
  not the pin.

## Related Issues

- PR #1 — <https://github.com/unclesp1d3r/markua-pandoc/pull/1> — "chore:
  bootstrap repo with plan, CI, and contributor docs" (open as of this
  writing; the commits above land as part of this branch, not yet merged to
  `main`). **Every commit SHA cited in this doc is branch-local to PR #1 and
  will be rewritten if that PR squash- or rebase-merges.** PR #1 is the
  durable reference; locate an individual change by its commit subject
  rather than by SHA.
- `AGENTS.md:54-67` ("Toolchain") — the canonical policy this learning is a
  concrete instance of. `CONTRIBUTING.md` ("Setup") states the same
  `mise use` + `mise lock --platform linux-x64` pairing for contributors.
- `docs/plan.md` Step 2 ("Install the Lua toolchain") still documents the
  pre-`mise` setup path (`brew install lua luarocks` plus a manual `PATH`
  export), which contradicts `AGENTS.md`/`CONTRIBUTING.md` and the
  `mise install` recipe embedded later in the same document. Worth a
  documentation refresh; out of scope for this fix.
- Commit `7ff2b17` — "fix: select pandoc deb by host architecture; declare
  shellcheck" — the architecture-hardcoding bug in the pre-`mise` bootstrap
  instructions, cited above as a parallel example of hand-rolled installer
  cost.
