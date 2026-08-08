# Contributing to markua-pandoc

Thanks for your interest. This document covers setup, the workflow the project
expects, and the few rules that are genuinely load-bearing.

Read [`AGENTS.md`](AGENTS.md) for the architecture and [`docs/plan.md`](docs/plan.md)
for the full design record and task breakdown.

## Setup

[mise](https://mise.jdx.dev) is the single source of truth for the toolchain.
`mise.toml` pins lua, pandoc, just and shellcheck, and `mise.lock` pins the exact
artifacts, so a local machine and CI resolve the same versions rather than
drifting apart.

```sh
mise install     # the pinned toolchain
just setup       # the above, plus busted
```

`busted` is the one exception: it is a luarocks package rather than a mise tool,
so `just setup` fetches it after `mise install`. The lua plugin bundles luarocks,
so it is already on your path. Add the rock binaries to yours:

```sh
export PATH="$HOME/.luarocks/bin:$PATH"
```

Confirm the toolchain resolves — CI runs this same check and fails on a pandoc
older than 3.10, which the custom reader API requires:

```sh
lua -v
luarocks --version | head -1
just --version
busted --version
pandoc --version | head -1 | awk '{split($2, v, "."); if (v[1] < 3 || (v[1] == 3 && v[2] < 10))
  { print "pandoc " $2 " is too old; 3.10+ required"; exit 1 } else print "pandoc " $2 " ok" }'
```

Change tool versions with `mise use <tool>@<version>` rather than editing
`mise.toml` by hand, so the lockfile stays in step. After changing one, run
`mise lock --platform linux-x64` as well: CI installs in `--locked` mode and a
tool missing a Linux entry fails the build.

## Running the tests

```sh
just           # list every available recipe
just test      # everything: unit + golden + filters + cli
just unit      # busted specs only — fast, run these constantly
just golden    # pandoc AST comparison against test/golden/*.native
just filters   # builds real DOCX files and asserts on their XML
just cli       # exercises bin/markua end to end
```

To regenerate golden files after an intentional change:

```sh
UPDATE=1 ./test/golden.sh
```

**Read the regenerated files before committing them.** A golden file generated from
broken code locks in the bug, and the diff is the only thing standing between a
subtle AST regression and `main`.

## The rules that matter

Most style is negotiable. These are not:

1. **No `pandoc` module outside `src/markua.lua` and `src/filters/*.lua`.**
   busted runs under system Lua, where the `pandoc` global does not exist. Every
   module under `src/markua/` must be pure Lua so it stays unit-testable. If you
   find yourself wanting `pandoc.read` in `blocks.lua`, the design is telling you
   the logic belongs somewhere else.

2. **Every transform must be fence-aware.** Content inside a fenced code block is
   never Markua. Real manuscripts contain JSON blocks whose lines start with `{`,
   and a naive attribute-list match will corrupt them. Consume `scanner.scan`
   output; never re-scan raw text.

3. **Unknown constructs are hard errors.** An unrecognized `{...}` attribute line
   aborts with file and line number. It must never leak literal braces into the
   output — a silent pass-through is a corrupted book that nobody notices until
   the proof copy arrives.

4. **Lua patterns, not regex.** No alternation, no lookahead, no non-greedy `+`.
   Match multiple alternatives with an explicit loop over a table of patterns.

## Workflow

The project is test-driven, and the plan is written that way task by task:

1. Write the failing test.
2. Run it. Confirm it fails, and that it fails for the reason you expect.
3. Write the minimum code to pass.
4. Run it again. Confirm it passes.
5. Refactor if needed, then commit.

When the whole-book smoke test surfaces a construct the fixtures never anticipated:

```sh
./test/book.sh /path/to/some/manuscript
```

add a focused unit test to the module that owns that construct, watch it fail, then
fix the module. Do not special-case a document inside `src/markua.lua`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), with a DCO sign-off:

```text
feat: fence-aware line scanner
fix: do not split attribute values on commas inside quotes
test: golden case for hierarchical index entries
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

Sign off every commit with `git commit -s`. This adds the `Signed-off-by` trailer
certifying you have the right to submit the work under the project's license.

## Pull requests

- Branch off `main`.
- CI must be green. It runs the full suite on Lua 5.4, the version pandoc
  embeds and therefore the one that actually executes the reader.
- New syntax support needs both a unit test and a golden case.
- Note anything you deliberately left out of scope.

## Scope

Out of scope for v1, by decision rather than oversight: quizzes and exercises (the
Markua 0.10 course constructs, rejected with a clear error), smart crosslinks,
`Book.txt` multi-file assembly, emoji shortcodes, and Leanpub document settings.
See the end of [`docs/plan.md`](docs/plan.md) for the reasoning on each.

If you want one of these, open an issue before building it — several were rejected
for structural reasons that are not obvious from the syntax alone.
