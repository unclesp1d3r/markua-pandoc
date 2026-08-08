# markua-pandoc — Agent Guide

A pandoc custom reader that parses Markua 0.30 so any Leanpub manuscript can be
converted to DOCX, EPUB, LaTeX, ICML, or HTML in one command, preserving index
entries and resource attributes that a markdown-to-markdown pipeline cannot carry.

The authoritative design and task breakdown lives in [`docs/plan.md`](docs/plan.md).
Read it before making structural changes.

Solutions to problems already solved here live in [`docs/solutions/`](docs/solutions/),
organized by category with YAML frontmatter (`module`, `tags`, `problem_type`) —
relevant when implementing or debugging in a documented area.
Shared domain vocabulary lives in [`CONCEPTS.md`](CONCEPTS.md).

## Architecture

A **delegating reader**. Markua-only syntax is rewritten in pure Lua into
pandoc-flavored markdown (fenced divs, bracketed spans, `$$` math), then handed to
`pandoc.read` so pandoc's own parser handles all the CommonMark-shaped work. A
second layer of Lua filters turns the resulting AST annotations into
output-format-specific constructs (Word `XE` index fields, named paragraph styles).

A native from-scratch Markua parser is **explicitly out of scope**: it would mean
reimplementing CommonMark in Lua.

## Hard constraints

These are load-bearing. Violating them breaks the test strategy or corrupts real
manuscripts.

- **No `pandoc` module outside `src/markua.lua` and `src/filters/*.lua`.** busted runs
  under system Lua, where the `pandoc` global does not exist. Every module under
  `src/markua/` must be pure Lua and unit-testable without pandoc. This is the single
  most important structural rule.
- **Fence-awareness is mandatory in every transform.** Content inside fenced code
  blocks is never Markua. Real manuscripts contain JSON code blocks whose lines begin
  with `{`, which a naive attribute-list match will corrupt. `scanner.lua` is the only
  module that knows about fences; everything else consumes its output.
- **Unknown constructs are hard errors.** An unrecognized `{...}` attribute line must
  abort with file and line number, never pass through as literal braces into the
  output. A `--lenient` flag may downgrade this to a warning.
- **Lua patterns, not regex.** Lua has no alternation, no lookahead, and no non-greedy
  `+`. Multi-alternative matching is done with explicit loops over a table of patterns.
- **Target Markua 0.30.** Quizzes and exercises (the Markua 0.10 course constructs) are
  out of scope and must be rejected with a clear error, not silently dropped.
- **Blurb/aside classes are configurable, not hardcoded.** The documented set is
  `warning`, `tip`, `note`, `information`, `error`, `question`, `discussion`,
  `exercise` — but real Leanpub builds reject `note`, and books restrict the set
  further. Ship the documented list as a default that config can override.

## Syntax variants that must both work

- **Two index syntaxes.** `{ix: "term"}` is the spec form and is canonical. `{i: "term"}`
  is a widespread real-world variant and must also be accepted. `!` creates hierarchy in
  both (`{ix: "Trees!B-tree"}`).
- **Two blurb syntaxes.** `{class: tip}` on the line above a run of `B>` lines is the spec
  form. `{blurb, class: tip}` … `{/blurb}` is the fenced form Leanpub also accepts.

## Toolchain

[mise](https://mise.jdx.dev) is the single source of truth. `mise.toml` pins the
versions and `mise.lock` pins the artifacts, so local and CI resolve identically.
Change a version with `mise use <tool>@<version>`, never by editing `mise.toml`
directly, then `mise lock --platform linux-x64` so CI's `--locked` install still
resolves.

- **pandoc 3.10+** — the custom reader API and GitHub-alert parsing both depend on
  it. pandoc embeds Lua 5.4, so that is the interpreter that actually executes the
  reader in production.
- **Lua 5.4** — the target runtime. The mise lua plugin bundles luarocks.
- **busted** — unit tests. **luacheck** — Lua linting, enforced by `just lint`
  and CI. Both are luarocks packages rather than mise tools, so they are declared
  in `markua-pandoc-dev-1.rockspec` and `just install` fetches them.

## Workflow

Test-driven, per `docs/plan.md`: write the failing test, watch it fail, implement the
minimum, watch it pass, commit.

```sh
just           # list the available recipes -- the authoritative list
just test      # everything currently wired up
just unit      # busted only

# Added with the scripts they run: golden (Task 9), filters (Task 10),
# cli (Task 12). Regenerate golden files with UPDATE=1 ./test/golden.sh
```

Golden files generated from broken code lock in the bug — **read them before committing.**

When the whole-book smoke test (`./test/book.sh <manuscript>`) surfaces an unhandled
construct, add a focused unit test to the module that owns it and fix the module. Do not special-case a document in `src/markua.lua`.
