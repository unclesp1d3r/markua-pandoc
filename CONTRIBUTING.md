# Contributing to markua-pandoc

Thanks for your interest. This document covers setup, the workflow the project
expects, and the few rules that are genuinely load-bearing.

Read [`AGENTS.md`](AGENTS.md) for the architecture and [`docs/plan.md`](docs/plan.md)
for the full design record and task breakdown.

## Setup

```sh
# pandoc 3.10+ is required: the custom reader API depends on it.
brew install pandoc lua luarocks        # macOS
# sudo apt install pandoc lua5.4 luarocks   # Debian/Ubuntu

luarocks install --local busted
export PATH="$HOME/.luarocks/bin:$PATH"

busted --version
pandoc --version | head -1
```

## Running the tests

```sh
make test      # everything: unit + golden + filters + cli
make unit      # busted specs only — fast, run these constantly
make golden    # pandoc AST comparison against test/golden/*.native
make filters   # builds real DOCX files and asserts on their XML
make cli       # exercises bin/markua end to end
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

```
feat: fence-aware line scanner
fix: do not split attribute values on commas inside quotes
test: golden case for hierarchical index entries
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.

Sign off every commit with `git commit -s`. This adds the `Signed-off-by` trailer
certifying you have the right to submit the work under the project's license.

## Pull requests

- Branch off `main`.
- CI must be green. It runs the full suite on Lua 5.4 and 5.5.
- New syntax support needs both a unit test and a golden case.
- Note anything you deliberately left out of scope.

## Scope

Out of scope for v1, by decision rather than oversight: quizzes and exercises (the
Markua 0.10 course constructs, rejected with a clear error), smart crosslinks,
`Book.txt` multi-file assembly, emoji shortcodes, and Leanpub document settings.
See the end of [`docs/plan.md`](docs/plan.md) for the reasoning on each.

If you want one of these, open an issue before building it — several were rejected
for structural reasons that are not obvious from the syntax alone.
