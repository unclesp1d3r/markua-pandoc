# Markua Pandoc Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `markua-pandoc`, a pandoc custom reader that parses Markua 0.30 (minus quizzes and exercises) so a Leanpub manuscript file can be converted to DOCX, EPUB, LaTeX, ICML, or HTML in one command, preserving index entries and resource attributes that a markdown-to-markdown pipeline structurally cannot carry.

The unit of work in v1 is **one manuscript file per invocation**. `Book.txt` ordering and multi-file assembly stay the caller's job (see "Out of scope for v1"), so a whole book is a loop over `markua`, not a single call. Index lowering ships Word-first; see the open question on the other four writers.

**Architecture:** A *delegating* reader. Markua-only syntax is rewritten in pure Lua into pandoc-flavored markdown (fenced divs, bracketed spans, `$$` math), then handed to `pandoc.read` so pandoc's own parser handles all the CommonMark-shaped work. A second layer of Lua filters turns the resulting AST annotations into output-format-specific constructs (Word `XE` index fields, named paragraph styles). A native from-scratch Markua parser is explicitly out of scope: it would mean reimplementing CommonMark in Lua, which is months of work and worse than pandoc's parser.

**Tech Stack:** Lua 5.4, pandoc 3.10+ (custom reader API, `pandoc.read`, Lua filters), busted for unit tests, shell-driven golden-file tests, LuaRocks for dependency install.

## Global Constraints

- **Target Markua version: 0.30.** Quizzes and exercises (the Markua 0.10 course constructs) are out of scope for v1 and must be rejected with a clear error, not silently dropped.
- **Pandoc 3.10 or newer.** The custom reader API and GitHub-alert parsing both depend on it.
- **No `pandoc` module outside `src/markua.lua` and `src/filters/*.lua`.** busted runs under system Lua, where the `pandoc` global does not exist. Every module under `src/markua/` must be pure Lua and unit-testable without pandoc. This is the single most important structural rule in the plan.
- **Fence-awareness is mandatory in every transform.** Content inside fenced code blocks is never Markua. Real manuscripts contain JSON code blocks whose lines begin with `{`, which a naive attribute-list match will corrupt.
- **Unknown constructs are hard errors.** An unrecognized `{...}` attribute line must abort with file and line number, never pass through as literal braces into the output. `bin/markua --lenient` downgrades this to a warning. Because pandoc's `ReaderOptions` rejects unknown fields, the wrapper passes the flag to the reader through `MARKUA_LENIENT` in the environment rather than through `opts`.
- **Lua patterns, not regex.** Lua has no alternation, no lookahead, and no non-greedy `+`. Multi-alternative matching is done with explicit loops over a table of patterns.
- **Two index syntaxes.** `{ix: "term"}` is the Markua spec form and is canonical. `{i: "term"}` is a widespread real-world variant and must also be accepted. `!` creates hierarchy in both (`{ix: "Trees!B-tree"}`).
- **Two blurb syntaxes.** `{class: tip}` on the line above a run of `B>` lines is the spec form. `{blurb, class: tip}` ... `{/blurb}` is the fenced form Leanpub also accepts. Both must work.
- **Blurb/aside classes are configurable, not hardcoded.** The documented set is `warning`, `tip`, `note`, `information`, `error`, `question`, `discussion`, `exercise`, but real Leanpub builds reject `note`, and books restrict the set further. Ship the documented list as a default that a config file can override. The override is a Lua table returned by a file passed to `bin/markua --config`, loaded in a sandboxed environment and merged over the defaults (Task 4 and Task 9).

---

## Key Technical Decisions

Settled in review on 2026-08-08. Each was checked against pandoc's own source
and behavior rather than chosen on taste, so the rationale names what was
verified.

- **Index spans use pandoc's own shape: class `indexref`, attribute `entry`.**
  This is what pandoc's Docx reader emits when it parses a Word `XE` field, so
  `markua -> docx -> pandoc` returns the identical span. That round trip is the
  golden-test oracle, replacing a grep for `XE "` that would pass on a field
  containing the wrong text. *(Rejected: the `.index` + `term` shape from the
  AsciiDoc reader, and DocBook's structured `primary`/`secondary`, both of
  which lose the round trip.)*

- **The callout class is the head of the class list, `.blurb` follows it.**
  pandoc's DocBook writer matches only the first class, so `{.blurb .tip}`
  degrades to a bare `<para>` with no error anywhere while `{.tip .blurb}`
  becomes a real `<tip>`. This head-class shape is also what pandoc's DocBook
  and GitHub-alert readers produce, so one downstream filter serves callouts
  from any of the three sources. The order is pinned by a test.

- **Index lowering ships for Word, LaTeX, and DocBook; HTML and EPUB need no
  filter.** pandoc's HTML writer renders unknown span attributes as `data-`
  attributes, so an index span already arrives as
  `<span class="indexref" data-entry="B-tree">`. LaTeX is nearly free because
  `!` is its subentry separator too, so hierarchy needs no translation; Word
  needs `!` mapped to `:`; DocBook needs the levels split into nested elements.
  *(ICML has no index primitive and is documented as unsupported.)*

- **The LaTeX filter injects `makeidx` into `header-includes`.** A bare
  `\index{}` compiles silently and prints nothing, which is exactly the
  ship-a-book-with-no-index failure this project exists to prevent. Where the
  index prints stays the author's call, so `\printindex` is not injected.

- **Colliding delimiters are escaped, not rejected.** A body line of exactly
  `:::` or `$$` is backslash-escaped, matching what pandoc's markdown writer
  does; the escaped form reads back to the identical AST. A hard error here
  would refuse documents pandoc handles without complaint. *(Rejected: the
  hard-error rule that the unknown-construct constraint would otherwise imply
  -- that constraint is about unrecognized Markua input, not about output the
  reader itself generates.)*

- **Code and CSV-table resources are lowered in v1; video and audio are not.**
  A manuscript whose code samples silently vanish is the worst failure this
  tool can have, and CSV maps onto a pandoc `Table` directly. Video and audio
  have no print target and no native pandoc node, so they stay annotated spans.

- **Matter directives carry the bare word verbatim** (`frontmatter`, not
  `front`), matching what the attribute parser already produces, so there is no
  mapping table to drift.

Settled while implementing Tasks 2 and 3. Each was found by executing the
reference source this document ships, not by reading it, so the rationale names
what was run.

- **Indentation is measured in columns, expanding tabs to 4-column stops.**
  Counting space characters scores a tab as zero, which reported a
  tab-indented `{timeout: 30}` as prose. pandoc 3.10.1 parses that line -- and
  the same line preceded by two spaces and a tab, where the tab advances to the
  next stop -- as a `CodeBlock`, so the attribute-list transform would have rewritten a code
  sample, the exact corruption fence-awareness exists to prevent. The same
  measure governs the fence-indent test, because a tab-indented ` ``` ` is an
  indented code block to pandoc, not a fence. *(Rejected: scoring a tab as one
  column, which keeps that line a fence and disagrees with pandoc.)*

- **`scanner.scan` normalizes CRLF and lone CR to LF.** The scanner already
  owns line splitting, so it is the one place a carriage return can be removed
  once instead of in every later transform. CRLF is substituted before lone CR;
  the reverse order collapses `\r\n` into `\n\n` and invents a blank line. This
  one is proactive rather than a fix for observed breakage -- no manuscript in
  the repository uses CRLF -- but the cost is one function and the alternative
  surfaces at Task 13 with every module to fix at once.

- **A value is carried by its quote character, not by escaping.** The reader
  calls `pandoc.read` with `markdown_strict` plus extensions, which leaves
  `all_symbols_escapable` OFF, so only original Markdown's escapable set works
  there: a backslash is in it, a double quote is not. Verified against pandoc
  3.10.1 under that exact format -- `{title="He said \"hi\""}` does **not**
  parse, and pandoc abandons the construct and renders the `:::` delimiters as
  literal paragraph text, while `{title='He said "hi"'}` parses to the value
  `He said "hi"`. So `to_pandoc_attr` single-quotes a value containing a double
  quote, double-quotes it otherwise, and still escapes backslashes. A value
  carrying *both* quote characters is unrepresentable in this syntax and is a
  hard error rather than silent corruption. *(Rejected: backslash-escaping the
  quote, which is what plain `-f markdown` accepts -- that was measured against
  the wrong format and would have leaked braces into every book with a quoted
  title. Rejected: adding `all_symbols_escapable` to the target format, which
  would change escaping semantics for the whole document to fix one field.)*

- **An id or class is emitted only in pandoc's own grammar.** From
  `Readers/Markdown.hs`: an id is `many1 (alphaNum <|> oneOf "-_:.")` and a
  class is `letter` then the same set, so an id may begin with a digit and a
  class may not, and neither may carry anything else. Outside that grammar
  pandoc rejects the *entire* attribute block, so `{#a&b .3things}` does not
  merely lose a name -- it leaks braces into the prose and drops every other
  attribute with it. `to_pandoc_attr` raises instead, naming the offender.
  Bytes above ASCII are accepted, since pandoc's `alphaNum` is Unicode-aware
  and `café` is a legal id; matching that exactly would need a Unicode table in
  pure Lua, and erring toward acceptance keeps real author text working.

- **`TARGET_FORMAT` must carry `fenced_code_blocks`.** The Markua spec allows a
  tilde delimiter -- "You can also insert an inline resource using three or more
  tildes (`~`) as the delimiter, instead of the more typical backticks" -- and
  `backtick_code_blocks` alone does not enable it. Without the extension pandoc
  parses a legitimate `~~~` block as a paragraph containing `Subscript`
  artifacts, so the block renders as garbled prose in every writer while the
  scanner correctly reports it as code. Verified against pandoc 3.10.1 both
  ways. This is why the scanner's fence table and the reader's format list have
  to be changed together.

- **The scanner is measured against the reader's own target format, not
  CommonMark.** `pandoc.read` is called with `markdown_strict` plus the
  extension list above, and that dialect disagrees with CommonMark where it
  matters here: an unclosed fence is a code block running to EOF in
  `commonmark` and `gfm`, but is *not a fence at all* in `markdown_strict` --
  the delimiter stays literal text. The scanner follows the target format, so
  an unterminated fence reverts to prose. Modelling the spec instead would make
  the scanner and the parser it feeds disagree, which is the one thing this
  module cannot afford. *(Rejected: following the CommonMark rule, which is
  more famous and wrong for this pipeline.)*

- **Indentation is measured from the container's content column.** A blockquote
  prefix is stripped before anything else, and a list item shifts where its
  content begins, so `1. item` followed by a four-space line is a lazy
  paragraph continuation rather than code -- content column 3, and 4 < 3 + 4.
  Measuring from column 0 made the scanner blind to every fence inside a `>`
  quote and made it report an author's habitually-indented `{ix: "term"}` under
  a numbered step as code, silently dropping the index entry. Both directions
  were found by differential testing against pandoc rather than by reading, and
  the fixtures are frozen as specs.

- **Duplicate attribute keys are first-wins with a warning, per the spec.**
  The Markua spec's *Attribute Keys* section is explicit: "If a key is
  duplicated in an attribute list, the first key value is used and subsequent
  ones are ignored. A Markua Processor should add a warning in its list of
  warnings, which are *not* output in the output itself." `class` is an
  ordinary attribute key, so a repeated `class:` does **not** accumulate --
  only the `.name` shortcut builds up a class list. A duplicate `id` follows
  the same first-wins rule. `parse` takes an optional sink for these warnings,
  which is the seam Task 4 uses to collect them into a real warning list
  instead of writing each to stderr. *(Rejected: last-wins, which was the
  incidental behavior of a Lua map; and raising a hard error, which the spec
  contradicts -- the document still has a defined meaning.)*

- **Parse permissively, emit strictly.** The two ends of this module answer to
  different traditions, and conflating them produced two bugs. Markua is a
  markdown dialect, and markdown has no such thing as a parse error, so `parse`
  recovers rather than rejecting: an unclosed quote stops delimiting, staying
  literal in the value while the following field still parses. That is measured
  pandoc behavior -- `{#h title="abc class=tip}` yields the value `"abc` *and*
  still applies the class `tip` -- and it fixes the silent field loss without a
  rule about which malformed input is illegal. Erroring instead would refuse
  `{title: 5" pipe}`, which parses correctly today. The output end faces XML's
  opposite rule, since DocBook and EPUB treat malformed markup as fatal, so
  `to_pandoc_attr` refuses to emit anything pandoc cannot read back. *(Rejected:
  raising on an unterminated quote, which needs a quote-opening rule Markua does
  not define and rejects input that works; and sanitizing an unsafe id, which
  silently rewrites an anchor the author cross-references elsewhere.)*

- **An unrepresentable id or class is a hard error, not an escape problem.**
  A value can always be carried by quoting and backslashes; an id or class
  cannot -- pandoc's attribute syntax has no escape for them. Measured against
  pandoc 3.10.1: `-`, `_`, `.` and a leading digit are accepted, while
  whitespace, a `"`, a brace, or an empty name makes pandoc reject the *entire*
  attribute block and render it as literal text. So `{#my id .a class}` does not
  just lose the id -- it leaks braces into the prose and drops the class too,
  the precise "never pass through as literal braces into the output" failure the
  global constraints forbid. `to_pandoc_attr` raises through `errors`, naming
  the offending id or class.

- **`split_fields` tracks backslash parity when it toggles quote state.**
  Flipping on every `"` leaves the tokenizer mis-synchronized after an odd
  number of escaped quotes: `{title: "She said \"hi, there\""}` truncated to
  `"She said \"hi` and invented a bare word `there\""`. This is tokenizing, not
  unescaping -- `parse` still hands `\"` through verbatim, because whether
  Markua defines an escape convention is a separate question from whether the
  parser may silently drop half a value.

**Independently implemented, not ported.** Where this reader mirrors a pandoc
behavior -- delimiter escaping, fence sizing -- the behavior was observed and
reimplemented in Lua. pandoc is GPL and this project is Apache-2.0; conventions
and interfaces are borrowed, source is not.

---

## File Structure

```text
markua-pandoc/
├── README.md
├── justfile                        # test, lint, install recipes
├── markua-pandoc-dev-1.rockspec    # declares busted; `just install` reads it
├── bin/
│   └── markua                      # POSIX sh wrapper around pandoc
├── src/
│   ├── markua.lua                  # Reader entry point. ONLY file using `pandoc`
│   ├── markua/
│   │   ├── scanner.lua             # line classification + fence tracking
│   │   ├── attributes.lua          # {key: value, #id, .class} parsing
│   │   ├── blocks.lua              # blurbs, asides, directives, headings
│   │   ├── inline.lua              # index, super/subscript, inline math
│   │   ├── resources.lua           # ![](x.ext) dispatch by extension
│   │   ├── config.lua              # class whitelist, strictness
│   │   └── errors.lua              # MarkuaError with file:line
│   └── filters/
│       ├── index-xe.lua            # index spans -> Word XE fields
│       ├── index-latex.lua         # index spans -> \index{} + makeidx preamble
│       ├── index-docbook.lua       # index spans -> <indexterm>
│       ├── resources.lua           # code/table resource spans -> real blocks
│       └── callouts.lua            # blurb/aside divs -> Word styles
└── test/
    ├── errors_spec.lua             # busted
    ├── scanner_spec.lua
    ├── attributes_spec.lua
    ├── config_spec.lua
    ├── blocks_spec.lua
    ├── inline_spec.lua
    ├── resources_spec.lua
    ├── golden.sh                   # pandoc integration tests
    ├── filters.sh                  # DOCX filter integration tests
    ├── cli.sh                      # bin/markua end-to-end test
    ├── book.sh                     # whole-manuscript smoke test
    └── golden/
        ├── <name>.md               # Markua input
        └── <name>.native           # expected pandoc AST
```

**Borrowed conventions.** The AST shapes this reader emits are pandoc's own,
not invented: index points are `Span`s with class `indexref` and attribute
`entry` (what pandoc's Docx reader produces from a Word `XE` field), and
callouts are a `Div` whose *head* class names the callout type followed by a
`.blurb` marker (what pandoc's DocBook and GitHub-alert readers both produce).
Following them buys three things for free -- callouts become real DocBook
`<tip>`/`<note>` elements, index spans survive into HTML and EPUB as
`data-entry` with no filter at all, and `markua -> docx -> pandoc` round-trips
to the identical span, which is a far stronger golden-test oracle than grepping
output XML.

**Responsibility boundaries.** `scanner.lua` is the only module that knows about fences, and every other block-level module consumes its output rather than re-scanning raw text. `attributes.lua` is a pure parser with no knowledge of what attributes mean. `blocks.lua` and `inline.lua` own the actual Markua-to-pandoc-markdown rewrites and are where nearly all the spec surface lives. `markua.lua` is deliberately tiny so that the untestable-under-busted surface stays near zero.

---

## Phase 1: Foundation

### Task 1: Repo skeleton and test harness

**Files:**

- Create: `justfile`, `markua-pandoc-dev-1.rockspec`
- (`README.md` and `.gitignore` already exist; Task 13 owns writing the README)
- Create: `src/markua/errors.lua`
- Test: `test/errors_spec.lua`

**Interfaces:**

- Consumes: nothing
- Produces: `errors.new(file, line, message) -> table` with fields `file`, `line`, `message` and a `__tostring` metamethod rendering `file:line: message`; `errors.raise(file, line, message)` which calls `error()` with that table.

- [ ] **Step 1: Create the repo skeleton**

The repository, `.gitignore` and `justfile` already exist from bootstrap, so
this is only the source tree. Do **not** recreate `.gitignore`: the committed
one is considerably more than these five lines, and it carries a `!bin/`
re-include that a wider global gitignore would otherwise defeat.

Create only the directories this task puts files in. Git does not track empty
directories, so `src/filters`, `bin` and `test/golden` would not survive a
clone; Tasks 9 through 12 create them alongside their first file.

```bash
mkdir -p src/markua test
```

- [ ] **Step 2: Install the Lua toolchain**

busted runs under system Lua and will NOT have pandoc's `pandoc` module. That is intentional and shapes the whole design.

mise owns the toolchain -- do not `brew install lua`, or the interpreter under
test stops matching the pinned one that CI and pandoc use. The lua plugin
bundles luarocks, so busted is the only thing luarocks fetches directly.

```bash
just setup                    # mise install, then `just install` for busted
export PATH="$HOME/.luarocks/bin:$PATH"
busted --version
```

- [ ] **Step 3: Write the failing test**

Create `test/errors_spec.lua` (this is the shipped file, verbatim):

```lua
-- Spec for the structured error type (src/markua/errors.lua).
--
-- Written before the module exists: Task 1's TDD cycle starts red. Run with
-- `busted test/errors_spec.lua` from the repo root -- require("src.markua.errors")
-- resolves through stock package.path only from there.
local errors = require("src.markua.errors")

-- errors.warn writes straight to io.stderr, so swapping the handle is the only
-- way to assert the Lenient path actually warned rather than silently returning.
-- Restores the real handle before returning so a failure cannot leak the stub.
-- errors.warn takes an optional sink, so the Lenient path's output can be
-- asserted without swapping the global io.stderr out from under the suite.
local function recording_sink()
  local chunks = {}
  return {
    write = function(_, ...)
      for _, piece in ipairs({ ... }) do
        chunks[#chunks + 1] = piece
      end
    end,
    text = function() return table.concat(chunks) end,
  }
end

describe("errors", function()
  it("renders file and line in the message", function()
    local err = errors.new("chapter-01.md", 42, "unknown attribute")
    assert.equals("chapter-01.md:42: unknown attribute", tostring(err))
  end)

  it("raises a structured error rather than a string", function()
    local ok, err = pcall(errors.raise, "a.md", 7, "boom")
    assert.is_false(ok)
    assert.equals("a.md", err.file)
    assert.equals(7, err.line)
    assert.equals("boom", err.message)
  end)

  it("reports fatally when strict", function()
    -- Assert the raised value, not just that something raised: report must
    -- surface the structured error, not a bare string.
    local ok, err = pcall(errors.report, { strict = true }, "a.md", 1, "boom")
    assert.is_false(ok)
    assert.equals("a.md", err.file)
    assert.equals(1, err.line)
    assert.equals("boom", err.message)
  end)

  it("downgrades to a warning when not strict", function()
    -- Without this path cfg.strict is dead config and --lenient does nothing.
    -- Asserting the written text is what proves the warning fired; checking the
    -- return value alone still passes when the warn call is deleted outright.
    local sink = recording_sink()
    local result = errors.report({ strict = false, sink = sink }, "a.md", 1, "boom")
    assert.is_false(result)
    assert.equals("warning: a.md:1: boom\n", sink.text())
  end)

  it("treats an absent or empty config as strict", function()
    assert.is_false((pcall(errors.report, nil, "a.md", 1, "boom")))
    assert.is_false((pcall(errors.report, {}, "a.md", 1, "boom")))
  end)

  it("treats a non-table config as strict rather than raising a raw index error", function()
    -- A scalar cfg used to reach `cfg.strict` and raise "attempt to index a
    -- number value" from inside this module, masking the real error.
    local ok, err = pcall(errors.report, 5, "a.md", 1, "boom")
    assert.is_false(ok)
    assert.equals("boom", err.message)
  end)

  it("renders a nil line literally instead of raising from __tostring", function()
    -- string.format("%s:%d: %s", ...) raises on a nil line (bad argument #3),
    -- masking the real error. %s with tostring() on each field must not crash.
    local err = errors.new("a.md", nil, "boom")
    assert.equals("a.md:nil: boom", tostring(err))
  end)

  it("renders a non-integer line literally instead of raising from __tostring", function()
    -- The other half of the %d hazard: %d rejects a float outright with
    -- "number has no integer representation".
    assert.equals("a.md:3.5: boom", tostring(errors.new("a.md", 3.5, "boom")))
  end)
end)
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `busted test/errors_spec.lua`
Expected: FAIL with "module 'src.markua.errors' not found"

- [ ] **Step 5: Implement the minimal code to make the test pass**

Create `src/markua/errors.lua`:

```lua
-- Structured errors carrying source position.
--
-- Every later module in this reader reports unknown constructs by file and
-- line. A shared error type lets callers inspect `.file` / `.line` directly
-- instead of parsing a rendered string back apart, and gives the documented
-- --lenient flag a single place (report) where the Strict/Lenient choice is
-- made.
local M = {}

local mt = {
  -- %s with tostring() on every field, not %d (docs/plan.md's original
  -- string.format("%s:%d: %s", ...)): %d raises on a nil or non-integer
  -- line, and that secondary error inside __tostring would mask the real
  -- one. CLI-level errors (Task 12) have no natural line number, so nil is
  -- a real input, not a hypothetical.
  __tostring = function(e)
    return string.format("%s:%s: %s", tostring(e.file), tostring(e.line), tostring(e.message))
  end,
}

--- Construct a structured error carrying source position.
function M.new(file, line, message)
  return setmetatable({ file = file, line = line, message = message }, mt)
end

--- Raise the table itself so callers can inspect .file / .line.
function M.raise(file, line, message)
  -- Level 0: Lua prepends position info only to string errors, and this
  -- table already carries its own file/line.
  error(M.new(file, line, message), 0)
end

--- Report without aborting. Used only when config.strict is false, so the
--- documented --lenient flag downgrades hard errors instead of being inert.
--- `sink` defaults to stderr; passing one makes the output assertable, and is
--- the seam a later caller would use to batch or cap a noisy full-book run.
function M.warn(file, line, message, sink)
  local out = sink or io.stderr
  out:write("warning: ", tostring(M.new(file, line, message)), "\n")
end

--- Raise when strict, warn otherwise. Every unknown-construct path goes
--- through here so leniency is one decision rather than scattered branches.
function M.report(cfg, file, line, message)
  -- The type check is load-bearing: a nil cfg would raise a nil-index error
  -- and a scalar one ("attempt to index a number value") would raise from
  -- inside this module, masking the very error it was called to report.
  -- Strict is the default for every shape except an explicit strict = false.
  if type(cfg) == "table" and cfg.strict == false then
    M.warn(file, line, message, cfg.sink)
    return false
  end
  M.raise(file, line, message)
end

return M
```

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `busted test/errors_spec.lua`
Expected: PASS, 8 successes

- [x] **Step 7: Add the justfile** — already in the repo

`justfile` was created during repo bootstrap and is reproduced here for
reference. It defines only the recipes whose scripts exist; `golden`, `filters`
and `cli` are added by Tasks 9, 10 and 12 as their scripts land, so that
`just test` never invokes a script that is not there yet.

Note that `just` uses the **last** comment line above a recipe as its
description, so each doc comment is a single self-contained line.

```just
# List the available recipes.
default:
    @just --list

# Everything CI runs.
test: unit

# busted unit specs. Fast; run these constantly.
unit:
    busted test/

# Install dev dependencies from the rockspec (busted is a luarocks package, not a mise tool).
install:
    luarocks install --local --only-deps markua-pandoc-dev-1.rockspec

# Full setup from a clean checkout: mise owns the toolchain, luarocks owns busted.
setup:
    mise install
    @just install

# Every pre-commit hook, across all files rather than just the staged ones.
lint:
    pre-commit run --all-files

clean:
    rm -rf build
```

- [ ] **Step 8: Add the dev rockspec**

`just install` and CI each hardcoded `luarocks install --local busted`, so the
one Lua dependency was named in two places. The rockspec is that name's single
home; `--only-deps` installs what it declares without building the rock, so
`build.type = "none"` is correct -- the reader ships as a pandoc script, not as
a luarocks module.

Create `markua-pandoc-dev-1.rockspec`:

```lua
package = "markua-pandoc"
version = "dev-1"

source = {
  url = "git+https://github.com/unclesp1d3r/markua-pandoc.git",
}

description = {
  summary  = "A pandoc custom reader for Markua 0.30",
  homepage = "https://github.com/unclesp1d3r/markua-pandoc",
  license  = "Apache-2.0",
}

-- Development dependencies only. lua itself comes from mise, not luarocks, but
-- declaring the floor keeps `luarocks install --only-deps` honest about it.
dependencies = {
  "lua >= 5.4",
  -- Pinned to floors rather than left open: an unconstrained dependency lets a
  -- clean CI run resolve a newer release than any commit chose.
  "busted >= 2.2, < 3.0",
  "luacheck >= 1.2, < 2.0",
}

-- Nothing to build: the reader is a pandoc script, not an installable module.
build = {
  type = "none",
}
```

Then point the `install` recipe at it and drop the duplicate from
`.github/workflows/ci.yml`:

```just
install:
    luarocks install --local --only-deps markua-pandoc-dev-1.rockspec
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: error type with source position and test harness"
```

---

### Task 2: Fence-aware line scanner

**Files:**

- Create: `src/markua/scanner.lua`
- Test: `test/scanner_spec.lua`

**Interfaces:**

- Consumes: nothing. The scanner has no error path, so it does not require `errors`.
- Produces: `scanner.scan(text) -> array of line records`. Each record is `{ text = string, number = integer, in_code = boolean, fence = "open"|"close"|nil, info = string|nil }`. `in_code` is true for lines *inside* a fence and for the fence delimiters themselves. `info` carries the fence info string (e.g. `python`, `$`) on the opening fence record.
- `scan` normalizes CRLF and lone CR to LF, so no record's `text` carries a stray carriage return and no downstream module has to special-case one.
- Joining every record's `text` with `\n` reproduces the normalized input exactly. Newline-terminated input therefore ends in an empty record, and that record's `number` counts one past the document's last real line — a caller reporting an error position straight from `record.number` must not assume every record names a line an author can open.

- [ ] **Step 1: Write the failing test**

Create `test/scanner_spec.lua`:

```lua
-- Spec for the fence-aware line scanner (src/markua/scanner.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run
-- with `busted test/scanner_spec.lua` from the repo root --
-- require("src.markua.scanner") resolves through .busted's lpath only from
-- there.
--
-- The first seven scenarios are docs/plan.md Task 2 Step 1's own spec,
-- carried over verbatim so a regression in the corrected module is visible
-- as a failure rather than a silent reclassification. Everything after them
-- covers this plan's three corrections: KTD1 (column-based indentation),
-- KTD2 (line-ending normalization), and KTD3 (the trailing-record round
-- trip) -- plus the remaining fence-boundary cases R4-R5 call for.
local scanner = require("src.markua.scanner")

describe("scanner", function()
  it("marks lines inside fences as code", function()
    local lines = scanner.scan('a\n```python\n{"k": 1}\n```\nb')
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[2].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("captures the fence info string", function()
    local lines = scanner.scan("```$\nx\n```")
    assert.equals("$", lines[1].info)
    assert.equals("open", lines[1].fence)
    assert.equals("close", lines[3].fence)
  end)

  it("only closes on a matching fence marker", function()
    -- a ``` inside a ~~~ block must not close it
    local lines = scanner.scan("~~~text\n```\nstill code\n~~~\nout")
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("numbers lines from one", function()
    local lines = scanner.scan("a\nb")
    assert.equals(1, lines[1].number)
    assert.equals(2, lines[2].number)
  end)

  it("recognises a fence indented up to three spaces", function()
    local lines = scanner.scan("text\n\n   ```json\n   {\"k\": 1}\n   ```\n")
    assert.is_true(lines[3].in_code)
    assert.equals("open", lines[3].fence)
    assert.is_true(lines[4].in_code)
  end)

  it("treats a four-space indented block as code", function()
    -- Without this, "    {timeout: 30}" reads as a Markua attribute list.
    local lines = scanner.scan("Consider:\n\n    {timeout: 30}\n\nDone.\n")
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("does not treat an indented continuation line as code", function()
    -- Four spaces only start a code block after a blank line.
    local lines = scanner.scan("A paragraph\n    wrapped by hand.\n")
    assert.is_false(lines[2].in_code)
  end)

  it("treats a tab-indented line after a blank line as code (KTD1)", function()
    -- A bare space count scores a tab as zero columns, so the reference
    -- scanner missed this. pandoc parses it as CodeBlock.
    local lines = scanner.scan("Consider:\n\n\t{timeout: 30}\n\nDone.\n")
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("treats two spaces then a tab as reaching column four (KTD1)", function()
    -- Column 2 plus a tab advances to the next 4-column stop, i.e. column 4.
    local lines = scanner.scan("Consider:\n\n  \t{timeout: 30}\n\nDone.\n")
    assert.is_true(lines[3].in_code)
  end)

  it("treats a tab-indented fence marker as indented code, not a fence (KTD1)", function()
    -- A tab advances to column 4, which is indented code to pandoc, not a
    -- fence -- so this line carries in_code but no fence field at all.
    local lines = scanner.scan("Consider:\n\n\t```\nDone.\n")
    assert.is_true(lines[3].in_code)
    assert.is_nil(lines[3].fence)
  end)

  it("normalizes CRLF line endings while keeping fence and info detection intact (KTD2)", function()
    local lines = scanner.scan('a\r\n```python\r\n{"k": 1}\r\n```\r\nb')
    for _, record in ipairs(lines) do
      assert.is_nil(record.text:find("\r"))
    end
    assert.equals("python", lines[2].info)
    assert.equals("open", lines[2].fence)
    assert.equals("close", lines[4].fence)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("splits a lone-CR document the same as its LF equivalent (KTD2)", function()
    local cr = scanner.scan("a\rb\rc")
    local lf = scanner.scan("a\nb\nc")
    assert.equals(#lf, #cr)
    for i = 1, #lf do
      assert.equals(lf[i].text, cr[i].text)
      assert.equals(lf[i].in_code, cr[i].in_code)
    end
  end)

  it("round-trips exactly when every record's text is joined with \\n (KTD3, R10)", function()
    local function round_trip(text)
      local lines = scanner.scan(text)
      local parts = {}
      for _, record in ipairs(lines) do
        parts[#parts + 1] = record.text
      end
      return table.concat(parts, "\n")
    end

    assert.equals("a\n", round_trip("a\n"))
    assert.equals("a", round_trip("a"))
    assert.equals("", round_trip(""))
    assert.equals("```\ncode\n```\n", round_trip("```\ncode\n```\n"))
    -- The round trip reproduces the NORMALIZED input, so CRLF in means LF out.
    assert.equals("a\nb\n", round_trip("a\r\nb\r\n"))
  end)

  it("numbers the trailing record one past the last real line (KTD3)", function()
    -- The sentinel record exists only for newline-terminated input, and its
    -- number names no line an author can open. Later modules report error
    -- positions straight from record.number, so pin both halves here.
    local terminated = scanner.scan("a\nb\n")
    assert.equals(3, #terminated)
    assert.equals(3, terminated[3].number)
    assert.equals("", terminated[3].text)

    local unterminated = scanner.scan("a\nb")
    assert.equals(2, #unterminated)
    assert.equals(2, unterminated[2].number)
  end)

  it("closes on a longer closing fence but not on a shorter one", function()
    local longer = scanner.scan("```\ncode\n````\nafter")
    assert.equals("close", longer[3].fence)
    assert.is_false(longer[4].in_code)

    -- A shorter delimiter does not close, so this fence never closes -- and
    -- an unclosed fence is not a fence under the reader's target format, so
    -- the whole run reverts to prose. Verified: pandoc parses this as one
    -- Para containing inline Code, not a CodeBlock.
    local shorter = scanner.scan("````\ncode\n```\nafter")
    assert.is_nil(shorter[3].fence)
    assert.is_false(shorter[3].in_code)
    assert.is_false(shorter[4].in_code)
  end)

  it("does not close an open fence when the delimiter carries an info string", function()
    local lines = scanner.scan("```\ncode\n```text\nstill code\n```\nafter")
    assert.is_nil(lines[3].fence)
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.equals("close", lines[5].fence)
    assert.is_false(lines[6].in_code)
  end)

  it("treats a fence that never closes as prose, not code", function()
    -- markdown_strict and its extensions -- the format the reader hands to
    -- pandoc.read -- require a fence to close before it is a fence at all;
    -- an unclosed one is literal text. commonmark and gfm instead run the
    -- block to EOF. Following the target format is what keeps this scanner's
    -- answer and pandoc's identical, which is the module's whole job.
    local lines = scanner.scan("```\na\nb\nc")
    for i = 1, #lines do
      assert.is_false(lines[i].in_code)
    end
    assert.is_nil(lines[1].fence)
  end)

  it("reverts an unclosed fence inside a blockquote when the quote ends", function()
    local lines = scanner.scan("> ```\n> quoted\n\nafter\n")
    assert.is_false(lines[1].in_code)
    assert.is_false(lines[2].in_code)
    assert.is_false(lines[4].in_code)
  end)
end)

-- Every expectation below is pandoc 3.10.1's own answer for the same input,
-- taken under the exact format the reader hands to pandoc.read
-- (markdown_strict plus its extensions) rather than reasoned from the spec.
-- The scanner exists to predict what pandoc will treat as code, so a
-- disagreement here is a scanner bug by definition.
describe("scanner container nesting", function()
  it("sees a fenced block inside a blockquote", function()
    local lines = scanner.scan('> ```python\n> {"k": 1}\n> ```\n\nafter\n')
    assert.is_true(lines[1].in_code)
    assert.equals("open", lines[1].fence)
    assert.equals("python", lines[1].info)
    assert.is_true(lines[2].in_code)
    assert.equals("close", lines[3].fence)
    assert.is_false(lines[5].in_code)
  end)

  it("sees an indented block inside a blockquote", function()
    -- A bare ">" is the blank line that opens the indented block.
    local lines = scanner.scan("> para\n>\n>     sample\n\nafter\n")
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("sees a fence nested two blockquotes deep", function()
    local lines = scanner.scan("> > ```\n> > sample\n> > ```\n")
    assert.is_true(lines[2].in_code)
  end)

  it("handles a blockquote marker with no space after it", function()
    local lines = scanner.scan(">```\n>sample\n>```\n")
    assert.is_true(lines[2].in_code)
  end)

  it("does not treat a four-space line under a numbered item as code", function()
    -- "1. " puts content at column 3, so code needs column 7. Four spaces is
    -- a lazy paragraph continuation -- and an attribute an author indents by
    -- habit there must still be converted, not skipped as code.
    local lines = scanner.scan("1. item one\n\n    {ix: \"term\"}\n\n2. item two\n")
    assert.is_false(lines[3].in_code)
  end)

  it("treats an eight-space line under a numbered item as code", function()
    local lines = scanner.scan("1. item one\n\n        sample\n\n2. item two\n")
    assert.is_true(lines[3].in_code)
  end)

  it("measures a bullet item's content column too", function()
    local indented = scanner.scan("- item\n\n      sample\n\n- two\n")
    assert.is_true(indented[3].in_code)

    local para = scanner.scan("- item\n\n  {ix: \"term\"}\n\n- two\n")
    assert.is_false(para[3].in_code)
  end)

  it("keeps a fence aligned to a wide list marker a fence, info string and all", function()
    -- "10. " puts content at column 4. Measuring from column 0 would reject
    -- the delimiter as over-indented and silently drop the language.
    local lines = scanner.scan("10. item ten\n\n    ```python\n    sample\n    ```\n")
    assert.equals("open", lines[3].fence)
    assert.equals("python", lines[3].info)
    assert.is_true(lines[4].in_code)
  end)

  it("handles a fence inside a list inside a blockquote", function()
    local lines = scanner.scan("> 1. item\n>\n>    ```\n>    sample\n>    ```\n")
    assert.is_true(lines[4].in_code)
  end)

  it("resumes plain measurement after a blockquote ends", function()
    local lines = scanner.scan("> quoted\n\n    sample\n")
    assert.is_true(lines[3].in_code)
  end)
end)

describe("scanner container-state isolation", function()
  it("does not let a closed quoted fence clear a later top-level list", function()
    -- The fence's blockquote depth outlived the fence, so a later top-level
    -- line looked like it had left a container and cleared the list's content
    -- column -- turning that item's lazy continuation into code.
    local lines = scanner.scan("> ```\n> x\n> ```\n\n1. item\n\n    {ix: \"term\"}\n")
    assert.is_false(lines[7].in_code)
  end)

  it("measures a list marker whose gap is a tab", function()
    -- pandoc reads "1.<tab>item" as a list, so its content column is 4 and a
    -- five-column line is a continuation, not code. Counting bytes instead of
    -- expanding the tab put the content column at 0 and called it code.
    local continuation = scanner.scan("1.\titem\n\n\t {ix: \"term\"}\n")
    assert.is_false(continuation[3].in_code)

    local code = scanner.scan("1.\titem\n\n\t\t sample\n")
    assert.is_true(code[3].in_code)
  end)

  it("measures a bullet marker whose gap is a tab", function()
    local lines = scanner.scan("-\titem\n\n\t {ix: \"term\"}\n")
    assert.is_false(lines[3].in_code)
  end)

  it("replays list context correctly when an unclosed fence reverts", function()
    -- The stray ``` is not a fence, so "1. item" is a lazy continuation of
    -- the paragraph it starts rather than a list -- no content column is
    -- opened, and the four-space line after the blank is ordinary top-level
    -- indented code. Verified against pandoc, which emits exactly that Para
    -- plus CodeBlock pair.
    local lines = scanner.scan("```\n1. item\n\n    {ix: \"term\"}\n")
    assert.is_false(lines[1].in_code)
    assert.is_false(lines[2].in_code)
    assert.is_true(lines[4].in_code)
  end)
end)

describe("scanner tilde fences", function()
  -- The Markua spec supports tildes as a fence delimiter: "You can also insert
  -- an inline resource using three or more tildes (`~`) as the delimiter,
  -- instead of the more typical backticks". pandoc only honours that with the
  -- `fenced_code_blocks` extension, which the reader's TARGET_FORMAT must
  -- therefore carry -- without it a legitimate ~~~ block parses as prose with
  -- Subscript artifacts, and every writer renders it wrong.
  it("treats a tilde fence as code, like a backtick fence", function()
    local lines = scanner.scan("~~~python\nsample\n~~~\n\nafter\n")
    assert.equals("open", lines[1].fence)
    assert.equals("python", lines[1].info)
    assert.is_true(lines[2].in_code)
    assert.equals("close", lines[3].fence)
    assert.is_false(lines[5].in_code)
  end)

  it("recognises a tilde fence inside a list item and a blockquote", function()
    local list = scanner.scan("- item\n\n  ~~~lua\n  sample\n  ~~~\n")
    assert.is_true(list[4].in_code)

    local quoted = scanner.scan("> ~~~\n> sample\n> ~~~\n")
    assert.is_true(quoted[2].in_code)
  end)

  it("does not let a backtick delimiter close a tilde fence", function()
    local lines = scanner.scan("~~~text\n```\nstill code\n~~~\nout\n")
    assert.is_true(lines[2].in_code)
    assert.is_true(lines[3].in_code)
    assert.equals("close", lines[4].fence)
    assert.is_false(lines[5].in_code)
  end)
end)

-- Boundary cases surfaced by mutation testing: each of these fails if the
-- named constant or comparison drifts, and each expectation is pandoc's own
-- answer under the reader's target format.
describe("scanner boundary arithmetic", function()
  it("pins the tab stop at four columns", function()
    -- "- item" puts content at column 2, so code needs column 6. One tab
    -- reaches column 4 -- a continuation. At a tab stop of 8 it would reach 8
    -- and be misread as code, silently dropping the attribute.
    local lines = scanner.scan("- item\n\n\t{ix: \"term\"}\n")
    assert.is_false(lines[3].in_code)
  end)

  it("does not treat a four-column-indented delimiter as a fence", function()
    -- A tab-indented ``` is indented code, not a fence. If the fence check
    -- accepted four columns, these two lines would pair up and swallow the
    -- prose between them.
    local lines = scanner.scan("Consider:\n\n\t```\nActual prose.\n\t```\n\nDone.\n")
    assert.is_nil(lines[3].fence)
    assert.is_false(lines[4].in_code)
  end)

  it("does not close a fence on a delimiter at a deeper blockquote depth", function()
    -- A code sample quoting a transcript can contain "> ```" as literal text.
    local lines = scanner.scan("```\ncode one\n> ```\nstill code\n```\nafter\n")
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.equals("close", lines[5].fence)
    assert.is_false(lines[6].in_code)
  end)

  it("does not re-anchor on a marker-shaped line inside indented code", function()
    -- Eight columns under a two-column item is code, and the fact that it
    -- starts with "- " must not make it a new nesting level.
    local lines = scanner.scan("- outer\n\n        - deep\n")
    assert.is_true(lines[3].in_code)
  end)

  it("restores the enclosing item's column when a nested list dedents", function()
    -- "10. " puts content at column 4 and the nested "- " at column 6. A line
    -- back at column 4 is a lazy continuation of the OUTER item, not code --
    -- resetting to top level instead made it code and dropped the attribute.
    local para = scanner.scan("10. outer\n\n    - nested\n\n    {ix: \"term\"}\n")
    assert.is_false(para[5].in_code)

    -- The nested "- " sits at content column 6, so code needs column 10 --
    -- eight columns is still a continuation of the nested item. Verified
    -- against pandoc, which emits a CodeBlock at ten columns and none at eight.
    local still_para = scanner.scan("10. outer\n\n    - nested\n\n        sample\n")
    assert.is_false(still_para[5].in_code)

    local code = scanner.scan("10. outer\n\n    - nested\n\n          sample\n")
    assert.is_true(code[5].in_code)
  end)

  it("counts a tab after a blockquote marker in columns, not bytes", function()
    -- The marker takes one column of the tab's expansion; the rest is real
    -- indentation. Eating the whole tab byte measured two columns short.
    local code = scanner.scan("> quoted\n>\n>\t  sample\n")
    assert.is_true(code[3].in_code)

    local para = scanner.scan("> quoted\n>\n>\t{ix: \"term\"}\n")
    assert.is_false(para[3].in_code)
  end)
end)

describe("scanner list-start rules", function()
  it("does not let a list marker interrupt an open paragraph", function()
    -- pandoc reads "para" then "1. item" as one lazy paragraph, so no list
    -- opens and the indented line after the blank is ordinary code. Treating
    -- the marker as a list start hid that code block behind a phantom item.
    local ordered = scanner.scan("para\n1. item\n\n    sample\n")
    assert.is_true(ordered[4].in_code)

    local bullet = scanner.scan("para\n- item\n\n    sample\n")
    assert.is_true(bullet[4].in_code)
  end)

  it("still opens a list after a blank line or a heading", function()
    local after_blank = scanner.scan("para\n\n1. item\n\n    {ix: \"term\"}\n")
    assert.is_false(after_blank[5].in_code)

    -- A list may follow a heading with no blank line, so the paragraph gate
    -- must not key on blankness alone.
    local after_heading = scanner.scan("# Heading\n- item\n\n      sample\n")
    assert.is_true(after_heading[4].in_code)
  end)

  it("treats a thematic break as a rule, not a list item", function()
    -- "- - -" matches the bullet pattern but pandoc emits HorizontalRule.
    for _, rule in ipairs({ "- - -", "* * *", "___" }) do
      local lines = scanner.scan("para\n\n" .. rule .. "\n\n    sample\n")
      assert.is_true(lines[5].in_code, "expected code after " .. rule)
    end
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/scanner_spec.lua`
Expected: FAIL with "module 'src.markua.scanner' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/scanner.lua`:

```lua
--- Split a document into line records, tracking fenced-code state.
--
-- Every other module consumes this instead of raw text. Content inside a
-- fence is never Markua: manuscripts contain JSON blocks whose lines start
-- with '{', which a naive attribute-list match would corrupt.
local M = {}

local TAB_STOP = 4

-- Display column of the byte at `stop`, expanding tabs to 4-column stops
-- (CommonMark's rule, verified against pandoc 3.10.1). Everything that needs a
-- column measures through here, so the fence check, the indented-code check
-- and the list-marker gap can never drift apart.
local function column_at(text, stop)
  local column = 0
  for i = 1, stop - 1 do
    if text:sub(i, i) == "\t" then
      column = column - (column % TAB_STOP) + TAB_STOP
    else
      column = column + 1
    end
  end
  return column
end

-- Column width of a line's leading whitespace. Matching only spaces would
-- score a tab as zero, which keeps a tab-indented "\t```" a fence and a
-- tab-indented "\t{timeout: 30}" prose -- both wrong: pandoc parses the first
-- as an indented code block and the second as a CodeBlock.
local function indent_columns(line)
  return column_at(line, #line:match("^[ \t]*") + 1)
end

-- The two fence markers, as a table rather than chained matches: Lua patterns
-- have no alternation, so every multi-alternative match in this reader is an
-- explicit loop over a table of patterns.
local FENCE_PATTERNS = { "^(```+)(.*)$", "^(~~~+)(.*)$" }

-- Returns marker and info string if the line opens or closes a fence.
-- Expects content with the container prefix and indentation already stripped:
-- the caller owns the 0-3 column rule, because only it knows the enclosing
-- list or blockquote's content column, and a raw-indentation check here would
-- get that wrong the moment a container shifted it.
local function fence_parts(line)
  local body = line:gsub("^ *", "")
  local marker, info
  for _, pattern in ipairs(FENCE_PATTERNS) do
    marker, info = body:match(pattern)
    if marker then
      break
    end
  end
  if not marker then
    return nil
  end
  return marker, (info or ""):match("^%s*(.-)%s*$")
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- Normalize CRLF and lone-CR line endings to LF before splitting, so no
-- downstream module -- most of which anchor Lua patterns on "$" or "\n" --
-- has to special-case a carriage return. CRLF must be substituted first: a
-- lone-CR pass run first would collapse "\r\n" into "\n\n", inventing a
-- blank line the source never had.
local function normalize_newlines(text)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("\r", "\n")
  return text
end

-- Strip a blockquote prefix, returning its depth and the content after it.
-- CommonMark allows up to three spaces before each ">" and swallows one
-- optional space after it. Without this the scanner is blind to every fence
-- and indented block inside a quote: pandoc parses "> ```python" as a real
-- CodeBlock, while a raw-line scanner sees prose and lets a later transform
-- rewrite the sample -- the corruption this module exists to prevent, just
-- one container deeper.
local function strip_blockquote(line)
  local depth, rest, column = 0, line, 0
  while true do
    local indent, tail = rest:match("^( ? ? ?)>(.*)$")
    if not indent then
      return depth, rest
    end
    column = column + #indent + 1          -- past the ">" itself
    -- The marker swallows one optional space. A tab is not one space: it
    -- expands to the next 4-column stop, the marker takes one column of that
    -- expansion, and the remainder is real indentation. Eating the whole tab
    -- byte instead loses those columns, so "> " + tab + two spaces measured 2
    -- columns here while pandoc measured 4 and made it a CodeBlock.
    local first = tail:sub(1, 1)
    if first == "\t" then
      local width = TAB_STOP - (column % TAB_STOP)
      rest = (" "):rep(width - 1) .. tail:sub(2)
    elseif first == " " then
      rest = tail:sub(2)
      column = column + 1
    else
      rest = tail
    end
    depth = depth + 1
  end
end

-- Content column of a list item's body, or nil when the line starts no item.
-- A bullet or ordered marker shifts where that item's content begins, and
-- CommonMark measures its nested code from there -- so "1. item" followed by
-- a four-space line is a lazy paragraph continuation (content column 3, and
-- 4 < 3 + 4), not code. Measuring from column 0 instead made the scanner
-- report that line as code and skip a Markua attribute an author indented by
-- habit under a numbered step. The gap after the marker may be a tab, which
-- pandoc still reads as a list, so both the indent and the gap expand through
-- the tab-stop rule rather than counting bytes.
local LIST_MARKERS = { "^([ \t]*)([-+*])([ \t]+)", "^([ \t]*)(%d+[.)])([ \t]+)" }

-- A thematic break is not a list, even though "- - -" matches the bullet
-- pattern. pandoc emits HorizontalRule for it, so treating it as a list start
-- opened a phantom item whose content column then hid a real code block.
local THEMATIC_CHARS = { ["-"] = true, ["*"] = true, ["_"] = true }

local function is_thematic_break(rest)
  local squeezed = rest:gsub("[ \t]", "")
  if #squeezed < 3 or not THEMATIC_CHARS[squeezed:sub(1, 1)] then
    return false
  end
  return squeezed:gsub("%" .. squeezed:sub(1, 1), "") == ""
end

local function list_content_column(rest, thematic)
  if thematic then
    return nil
  end
  for _, pattern in ipairs(LIST_MARKERS) do
    local indent, marker, gap = rest:match(pattern)
    if indent then
      return column_at(rest, #indent + #marker + #gap + 1)
    end
  end
  return nil
end

-- Re-run the indented-code rule over a range whose fence turned out never to
-- close. Same rules as the main loop, so a reverted range is classified
-- exactly as if the stray fence delimiter had never been treated as one.
local function reclassify(records, facts, from, to)
  local indented = false
  local prev_blank = from > 1 and facts[from - 1].blank or true
  for i = from, to do
    local fact = facts[i]
    local in_code = false
    if indented then
      if fact.blank or fact.relative >= 4 then
        in_code = true
      else
        indented = false
      end
    elseif prev_blank and not fact.blank and fact.relative >= 4 then
      indented, in_code = true, true
    end
    records[i].in_code = in_code
    records[i].fence = nil
    records[i].info = nil
    prev_blank = fact.blank
  end
end

function M.scan(text)
  text = normalize_newlines(text)

  local records, facts = {}, {}
  local open_marker, open_depth, open_index = nil, 0, nil
  local indented = false      -- inside a four-column indented code block
  local prev_blank = true     -- start of document counts as a blank
  -- A stack, not a single column: dedenting out of a nested item returns to
  -- the *enclosing* item's content column, not to top level. Resetting to 0
  -- made "10. outer" / "    - nested" / "    {ix: ...}" read as code, where
  -- pandoc keeps that last line a lazy continuation of the outer item.
  local list_stack = {}       -- { { column = n, depth = n }, ... }, innermost last
  -- A list marker cannot interrupt an open paragraph in this dialect: pandoc
  -- reads "para" then "1. item" as one lazy paragraph, so treating it as a
  -- list start opened a phantom item whose content column then reported a
  -- following indented code block as prose. Only a *top-level* open is gated;
  -- nesting inside an already-open list is unaffected.
  local in_paragraph = false
  local number = 0

  -- The "text .. \n" split (and the empty trailing record it produces for
  -- newline-terminated input) is load-bearing, not an off-by-one: it is what
  -- makes join(records, "\n") reproduce the input exactly (R10). Every
  -- transform stage scans and rejoins, so an exact round trip is what stops
  -- trailing newlines from drifting across stages. Do not trim it. Its one
  -- consequence: that trailing record's `number` counts one past the
  -- document's last real line, so a caller reporting an error position from
  -- `record.number` must not assume every record names a line an author can
  -- open.
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1

    -- Everything below measures the line's *content*, not its raw text: the
    -- blockquote prefix is stripped first, then indentation is taken relative
    -- to the enclosing list item's content column. A fence or indented block
    -- means the same thing at any container depth, so resolving the prefix
    -- once here keeps one rule instead of one per container.
    local depth, rest = strip_blockquote(line)

    -- Blankness is a property of the content, not the raw line: inside a
    -- quote, a bare ">" is the blank line that separates blocks.
    local blank = is_blank(rest)

    -- Leaving a blockquote ends any list opened inside it. That is the list's
    -- own container depth, not the fence's: keying this off open_depth let a
    -- closed quoted fence leave a stale depth behind, which then cleared a
    -- later top-level list and misread its lazy continuation as code. A blank
    -- line ends nothing -- a loose list keeps its item open across one.
    while #list_stack > 0 and list_stack[#list_stack].depth > depth do
      list_stack[#list_stack] = nil
    end
    local list_column = #list_stack > 0 and list_stack[#list_stack].column or 0

    local column = indent_columns(rest)
    -- Computed once and reused by both the list gate and the paragraph gate
    -- below; it squeezes the whole line, so doing it twice per prose line is
    -- the one duplicated scan in this loop.
    local thematic = not blank and is_thematic_break(rest)

    if not blank and not open_marker then
      local started = list_content_column(rest, thematic)
      if started and #list_stack == 0 and in_paragraph then
        started = nil        -- a marker cannot interrupt an open paragraph
      end
      if started and column <= list_column + 3 then
        list_stack[#list_stack + 1] = { column = started, depth = depth }
      elseif column < list_column then
        -- Dedent: pop only the items this line has actually left.
        while #list_stack > 0 and column < list_stack[#list_stack].column do
          list_stack[#list_stack] = nil
        end
      end
      list_column = #list_stack > 0 and list_stack[#list_stack].column or 0
    end

    -- A fence sits 0-3 columns past the container's content column; at four
    -- it is indented code instead. Measuring the stripped content means one
    -- fence rule serves every container depth.
    local relative = column - list_column
    local marker, info
    if relative >= 0 and relative <= 3 then
      marker, info = fence_parts((rest:gsub("^%s*", "")))
    end

    local record = { text = line, number = number, in_code = open_marker ~= nil }
    records[number] = record
    facts[number] = { blank = blank, relative = relative }

    if open_marker then
      -- Inside a fence: only a matching closer at the same blockquote depth
      -- counts. A shallower depth means the quote ended first, which under
      -- this reader's target format means the opener was never a fence.
      if depth < open_depth then
        reclassify(records, facts, open_index, number - 1)
        open_marker, open_index, open_depth = nil, nil, 0
        record.in_code = false
      elseif marker and depth == open_depth and marker:sub(1, 1) == open_marker:sub(1, 1)
         and #marker >= #open_marker and info == "" then
        record.fence = "close"
        -- Clear the depth with the fence: a stale open_depth outlives the
        -- construct it described and corrupts unrelated later state.
        open_marker, open_index, open_depth = nil, nil, 0
      end
    elseif marker then
      open_marker, open_depth, open_index = marker, depth, number
      indented = false
      record.in_code = true
      record.fence = "open"
      record.info = info
    else
      -- An indented code block starts four columns past the container's
      -- content column after a blank line, and runs until a non-blank line
      -- dedents. Without this, a code sample such as "    {timeout: 30}"
      -- reads as a Markua attribute list and gets rewritten -- the same
      -- corruption fences protect against.
      if indented then
        if blank then
          record.in_code = true          -- blank lines do not end the block
        elseif relative >= 4 then
          record.in_code = true
        else
          indented = false
        end
      elseif prev_blank and not blank and relative >= 4 then
        indented = true
        record.in_code = true
      end
    end

    prev_blank = blank
    if blank or record.in_code or thematic or rest:match("^#") then
      in_paragraph = false
    else
      in_paragraph = true
    end
  end

  -- A fence still open at the end of the document never closed, so under this
  -- reader's target format (markdown_strict plus extensions, not commonmark)
  -- its delimiter was ordinary text all along. commonmark would run the block
  -- to EOF instead; following the format actually handed to pandoc.read is
  -- what keeps the scanner's answer and pandoc's the same.
  if open_marker then
    reclassify(records, facts, open_index, number)
  end

  return records
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/scanner_spec.lua`
Expected: PASS, 44 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/scanner.lua test/scanner_spec.lua
git commit -m "feat: fence-aware line scanner"
```

---

### Task 3: Attribute-list parser

**Files:**

- Create: `src/markua/attributes.lua`
- Test: `test/attributes_spec.lua`

**Interfaces:**

- Consumes: `errors` from Task 1
- Produces:
  - `attributes.is_attribute_line(text) -> boolean` — true when the trimmed line is exactly `{...}`.
  - `attributes.parse(text, file, line) -> table` with fields `id` (string or nil), `classes` (array of strings), `keyvals` (map), and `bare` (array of bare words such as `blurb`, `frontmatter`, `mainmatter`, `backmatter`).
  - `attributes.to_pandoc_attr(parsed) -> string` rendering a pandoc attribute block like `{#id .cls key="val"}`.

- [ ] **Step 1: Write the failing test**

Create `test/attributes_spec.lua`:

```lua
-- Spec for the attribute-list parser (src/markua/attributes.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run with
-- `busted test/attributes_spec.lua` from the repo root -- require("src.markua.attributes")
-- resolves through .busted's lpath only from there.
--
-- The first six `describe("attributes.parse", ...)` scenarios and the
-- to_pandoc_attr id/classes/keyvals scenario are docs/plan.md Task 3 Step 1
-- verbatim. Everything below them covers the KTD4, KTD8, KTD5, and R17
-- corrections this plan makes to that reference module.
local attributes = require("src.markua.attributes")

-- Builds the parsed-attribute shape directly, without going through parse --
-- these cases exercise to_pandoc_attr on values parse would never produce, or
-- would decorate with its own file/line provenance.
local function attr(fields)
  fields = fields or {}
  return {
    id = fields.id,
    classes = fields.classes or {},
    keyvals = fields.keyvals or {},
    bare = fields.bare or {},
  }
end

describe("attributes.parse", function()
  it("parses key/value pairs", function()
    local a = attributes.parse('{title: "Hello, world", line-numbers: true}', "f.md", 1)
    assert.equals("Hello, world", a.keyvals["title"])
    assert.equals("true", a.keyvals["line-numbers"])
  end)

  it("does not split on commas inside quotes", function()
    local a = attributes.parse('{ix: "B-tree, invention of"}', "f.md", 1)
    assert.equals("B-tree, invention of", a.keyvals["ix"])
  end)

  it("parses id and class shortcuts", function()
    local a = attributes.parse("{#install, .wide}", "f.md", 1)
    assert.equals("install", a.id)
    assert.same({ "wide" }, a.classes)
  end)

  it("promotes class: to the classes list", function()
    local a = attributes.parse("{class: part}", "f.md", 1)
    assert.same({ "part" }, a.classes)
    -- The negative half is the whole point of promoting it: without this,
    -- a refactor that also wrote the pair through to keyvals stays green.
    assert.is_nil(a.keyvals["class"])
  end)

  it("collects bare words", function()
    local a = attributes.parse("{blurb, class: tip}", "f.md", 1)
    assert.same({ "blurb" }, a.bare)
    assert.same({ "tip" }, a.classes)
  end)

  it("recognises attribute lines", function()
    assert.is_true(attributes.is_attribute_line("  {class: tip}  "))
    assert.is_false(attributes.is_attribute_line('{"messages": [1]}, trailing'))
  end)
end)

describe("attributes.to_pandoc_attr", function()
  it("renders id, classes and keyvals", function()
    local a = attributes.parse('{#x, class: tip, title: "A B"}', "f.md", 1)
    assert.equals('{#x .tip title="A B"}', attributes.to_pandoc_attr(a))
  end)

  it("single-quotes a value containing a double quote (KTD4)", function()
    -- The reader's target format is markdown_strict plus extensions, which
    -- leaves all_symbols_escapable off, so `\"` is NOT an escape there and
    -- {title="He said \"hi\""} fails to parse -- pandoc abandons the whole
    -- construct and renders the ::: delimiters as literal text. Verified
    -- against pandoc 3.10.1 under that exact format: the single-quoted form
    -- parses back to the value `He said "hi"`.
    local a = attr({ keyvals = { title = 'He said "hi"' } })
    assert.equals([[{title='He said "hi"'}]], attributes.to_pandoc_attr(a))
  end)

  it("keeps double quotes for a value containing only an apostrophe", function()
    local a = attr({ keyvals = { title = "it's" } })
    assert.equals([[{title="it's"}]], attributes.to_pandoc_attr(a))
  end)

  it("raises for a value carrying both quote characters", function()
    -- Neither quoting style can enclose it and no escape is available, so
    -- this is unrepresentable rather than silently corrupted.
    local a = attr({ keyvals = { title = [[He said "hi" and it's]] } })
    assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 3))
  end)

  it("escapes a backslash in a value (KTD4)", function()
    -- pandoc spells a literal backslash as title="a\\b"; escape \ before "
    -- so the quote pass does not double-escape the backslashes it introduces.
    local a = attr({ keyvals = { path = "a\\b" } })
    assert.equals('{path="a\\\\b"}', attributes.to_pandoc_attr(a))
  end)

  it("orders emitted keyvals deterministically across repeated calls (R18)", function()
    local a = attr({ keyvals = { zeta = "1", alpha = "2" } })
    local first = attributes.to_pandoc_attr(a)
    local second = attributes.to_pandoc_attr(a)
    assert.equals(first, second)
    assert.equals('{alpha="2" zeta="1"}', first)
  end)
end)

describe("attributes.parse index variant", function()
  it("parses the widespread {i: ...} variant alongside {ix: ...}", function()
    local a = attributes.parse('{i: "B-tree"}', "f.md", 1)
    assert.equals("B-tree", a.keyvals["i"])
  end)
end)

describe("attributes.parse fenced-blurb bare words (KTD5, R16)", function()
  it("yields bare = {'/blurb'} so the fenced-blurb closer survives for blocks.lua", function()
    local a = attributes.parse("{/blurb}", "f.md", 1)
    assert.same({ "/blurb" }, a.bare)
  end)

  it("lands a field with an unparseable key in bare verbatim rather than dropping it", function()
    -- A space inside the key breaks the `^([%w%-_]+)%s*:%s*(.*)$` match, so
    -- this is neither a key/value pair, an id, nor a class shortcut.
    local a = attributes.parse("{bad key: value}", "f.md", 1)
    assert.same({ "bad key: value" }, a.bare)
  end)
end)

describe("attributes.parse backslash-parity tokenizing (KTD8, R14a)", function()
  it("does not split on a comma following a backslash-escaped quote inside a value", function()
    local a = attributes.parse('{title: "She said \\"hi, there\\""}', "f.md", 1)
    assert.equals('She said \\"hi, there\\"', a.keyvals["title"])
    assert.same({}, a.bare)
  end)
end)

describe("attributes.parse errors (R17)", function()
  it("raises a structured error carrying file and line when the text is not an attribute list", function()
    local ok, err = pcall(attributes.parse, "not braces", "f.md", 7)
    assert.is_false(ok)
    assert.equals("f.md", err.file)
    assert.equals(7, err.line)
  end)
end)

describe("attributes.parse unterminated-quote recovery", function()
  -- Follows pandoc: an unclosed quote does not delimit, so it stays literal in
  -- the value and the following field still parses. Erroring instead would
  -- refuse `{title: 5" pipe}`, which is valid today.
  it("keeps the stray quote in the value and still separates the next field", function()
    local a = attributes.parse('{title: "abc, class: tip}', "f.md", 1)
    assert.equals('"abc', a.keyvals["title"])
    assert.same({ "tip" }, a.classes)
  end)

  it("leaves a literal quote inside an unquoted value alone", function()
    local a = attributes.parse('{title: 5" pipe}', "f.md", 1)
    assert.equals('5" pipe', a.keyvals["title"])
  end)

  it("still groups a comma inside a balanced quoted value", function()
    local a = attributes.parse('{ix: "B-tree, invention of"}', "f.md", 1)
    assert.equals("B-tree, invention of", a.keyvals["ix"])
    assert.same({}, a.bare)
  end)
end)

describe("attributes.to_pandoc_attr name representability", function()
  -- pandoc has no escape syntax for an id or class: whitespace, a quote, a
  -- brace, or an empty name makes it reject the whole attribute block and
  -- render it as literal braces -- the output AGENTS.md forbids.
  it("raises with file and line for an id that pandoc cannot read back", function()
    local parsed = attributes.parse("{#my id}", "f.md", 7)
    local ok, err = pcall(attributes.to_pandoc_attr, parsed, "f.md", 7)
    assert.is_false(ok)
    assert.equals("f.md", err.file)
    assert.equals(7, err.line)
  end)

  it("raises for a class that pandoc cannot read back", function()
    local parsed = attributes.parse("{.a class}", "f.md", 9)
    local ok, err = pcall(attributes.to_pandoc_attr, parsed, "f.md", 9)
    assert.is_false(ok)
    assert.equals(9, err.line)
  end)

  it("accepts the punctuation pandoc does accept, including a leading digit", function()
    local a = attributes.parse("{#3things, .with-dash, .with_us, .with.dot}", "f.md", 1)
    assert.equals("{#3things .with-dash .with_us .with.dot}", attributes.to_pandoc_attr(a))
  end)

  -- The accepted shapes are pandoc's own grammar, from Readers/Markdown.hs:
  --   identifierAttr = char '#' >> many1 (alphaNum <|> oneOf "-_:.")
  --   identifier     = letter >> many (alphaNum <|> oneOf "-_:.")   -- class
  -- An id may therefore start with a digit or a dash; a class may not.
  it("rejects a class beginning with a digit, which pandoc will not parse", function()
    local a = attr({ classes = { "3things" } })
    assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 1))
  end)

  it("rejects a name carrying punctuation outside pandoc's set", function()
    for _, name in ipairs({ "a&b", "a%b", "a#b", "a<b>c" }) do
      local a = attr({ id = name })
      assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 1),
        "expected " .. name .. " to be rejected as an id")
    end
  end)

  it("accepts colon, dot and a leading dash in an id", function()
    local a = attr({ id = "a:b.c" })
    assert.equals("{#a:b.c}", attributes.to_pandoc_attr(a))
    local dashed = attr({ id = "--x" })
    assert.equals("{#--x}", attributes.to_pandoc_attr(dashed))
  end)

  it("accepts a non-ASCII name, which pandoc's Unicode alphaNum allows", function()
    local a = attr({ id = "caf\195\169", classes = { "na\195\175ve" } })
    assert.equals("{#caf\195\169 .na\195\175ve}", attributes.to_pandoc_attr(a))
  end)

  it("splits a class value on whitespace the way pandoc does", function()
    -- pandoc's keyValAttr: "class" -> cs ++ T.words val
    local a = attributes.parse('{class: "tip wide"}', "f.md", 1)
    assert.same({ "tip", "wide" }, a.classes)
    assert.equals("{.tip .wide}", attributes.to_pandoc_attr(a))
  end)
end)

describe("attributes.parse duplicate keys", function()
  -- Markua spec, "Attribute Keys": "If a key is duplicated in an attribute
  -- list, the first key value is used and subsequent ones are ignored. A
  -- Markua Processor should add a warning in its list of warnings, which are
  -- *not* output in the output itself."
  -- parse takes an optional sink for these warnings, so the spec asserts them
  -- instead of printing to stderr.
  local function sink()
    local written = {}
    return { write = function(_, ...) written[#written + 1] = table.concat({ ... }) end },
           function() return table.concat(written) end
  end

  it("keeps the first occurrence of a repeated key and warns", function()
    local out, text = sink()
    local a = attributes.parse('{title: "first", title: "second"}', "f.md", 1, out)
    assert.equals("first", a.keyvals["title"])
    assert.is_truthy(text():find("duplicate attribute key"))
    assert.is_truthy(text():find("f.md:1"))
  end)

  it("applies the same first-wins rule to a repeated class key", function()
    -- `class` is an ordinary attribute key, so it does not accumulate. The
    -- classes list exists for the `.name` shortcut, a different syntax.
    local out = sink()
    local a = attributes.parse("{class: tip, class: wide}", "f.md", 1, out)
    assert.same({ "tip" }, a.classes)
  end)

  it("keeps the first id and ignores a later one", function()
    local out, text = sink()
    local a = attributes.parse("{#first, #second}", "f.md", 1, out)
    assert.equals("first", a.id)
    -- Assert the warning actually fires: Task 4 consumes this sink to build
    -- the warning list the spec requires, so a silently dropped warning here
    -- would ship undetected.
    assert.is_truthy(text():find("duplicate id"))
  end)

  it("still accumulates distinct classes from the .name shortcut", function()
    local a = attributes.parse("{.tip, .wide}", "f.md", 1)
    assert.same({ "tip", "wide" }, a.classes)
  end)
end)

describe("attributes parse-to-emit composition", function()
  it("still shows the composition trap when parse is chained into to_pandoc_attr", function()
    -- parse yields Markua-level text with the source escape intact, and
    -- to_pandoc_attr renders what it is given, so chaining them without an
    -- unescape step carries the backslashes through. Whichever consumer
    -- first needs the round trip owns that step.
    local parsed = attributes.parse('{title: "a \\"b\\""}', "f.md", 1)
    assert.equals('a \\"b\\"', parsed.keyvals["title"])
    -- The value contains a double quote, so it emits single-quoted.
    assert.equals([[{title='a \\"b\\"'}]], attributes.to_pandoc_attr(parsed))
  end)

  it("round-trips a semantic value that carries no source escape", function()
    local parsed = attributes.parse('{title: "Chapter 3"}', "f.md", 1)
    assert.equals('{title="Chapter 3"}', attributes.to_pandoc_attr(parsed))
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/attributes_spec.lua`
Expected: FAIL with "module 'src.markua.attributes' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/attributes.lua`:

```lua
--- Parse Markua attribute lists: {key: value, "quoted", #id, .class}.
--
-- Pure syntax. This module has no opinion about what any attribute means;
-- blocks.lua and resources.lua interpret them. It never unescapes a source
-- value -- `\"` in `parse`'s input stays `\"` verbatim in the parsed value.
-- Consumers own rejecting bare words they do not recognize (e.g. an
-- unparseable key, or a construct-specific word like "blurb"); this module
-- only tokenizes.
--
-- `parse` and `to_pandoc_attr` are NOT inverses, and must not be chained
-- directly on a value carrying a source escape. `parse` yields Markua-level
-- text (`\"` still escaped); `to_pandoc_attr` expects semantic text and
-- escapes what it is given, so feeding one straight into the other turns
-- `She said \"hi\"` into a value pandoc reads back with literal backslashes.
-- Whichever consumer first needs the round trip owns the unescape step
-- between them; where that belongs is a Markua-spec question this module
-- deliberately does not answer.
local errors = require("src.markua.errors")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_attribute_line(text)
  local t = trim(text)
  return t:sub(1, 1) == "{" and t:sub(-1) == "}" and #t >= 2
end

-- Count the run of consecutive backslashes immediately before position i in
-- body (1-indexed, exclusive of i itself). Used to decide whether the `"` at
-- i is escaped: an odd count means the backslash run ends in an unescaped
-- backslash that swallows this quote, so it does not toggle quote state.
local function backslash_run_length(body, i)
  local count = 0
  local j = i - 1
  while j >= 1 and body:sub(j, j) == "\\" do
    count = count + 1
    j = j - 1
  end
  return count
end

-- Split on commas that are not inside double quotes.
--
-- A `"` toggles quote state only when it is not escaped -- i.e. when it is
-- preceded by an even number (including zero) of consecutive backslashes.
-- Without this, `{title: "She said \"hi, there\""}` desyncs on the first
-- escaped `"`: the naive every-quote-toggles version treats it as a closing
-- quote, so the comma after it splits the field, truncating the value to
-- `"She said \"hi` and inventing a spurious bare word `there\""`. This is
-- tokenizing only -- the backslash stays in the field text verbatim; `parse`
-- does not unescape it.
--
-- A quote that never closes does not delimit anything, so quote state is
-- disabled for the whole body rather than left stuck on. Without this,
-- `{title: "abc, class: tip}` swallows the following field: the comma stops
-- separating and `class: tip` disappears into the title with no error. This
-- follows pandoc, which recovers the same way -- `{#h title="abc class=tip}`
-- yields the value `"abc` AND still applies the class `tip`, keeping the
-- stray quote literally rather than rejecting the document. Erroring instead
-- would refuse input that parses correctly today, such as `{title: 5" pipe}`.
local function has_balanced_quotes(body)
  local open = false
  for i = 1, #body do
    if body:sub(i, i) == '"' and backslash_run_length(body, i) % 2 == 0 then
      open = not open
    end
  end
  return not open
end

local function split_fields(body)
  local quotes_delimit = has_balanced_quotes(body)
  local fields, buf, in_quote = {}, {}, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '"' and quotes_delimit and backslash_run_length(body, i) % 2 == 0 then
      in_quote = not in_quote
      buf[#buf + 1] = c
    elseif c == "," and not in_quote then
      fields[#fields + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
  end
  fields[#fields + 1] = table.concat(buf)
  return fields
end

local function unquote(v)
  local inner = v:match('^"(.*)"$')
  return inner or v
end

--- Parse an attribute list. `sink` is optional and only receives duplicate-key
--- warnings; it is the seam a later caller uses to collect them into the
--- warning list the Markua spec asks a Processor to keep, rather than writing
--- each one straight to stderr.
function M.parse(text, file, line, sink)
  local t = trim(text)
  local body = t:match("^{(.*)}$")
  if not body then
    errors.raise(file, line, "not an attribute list: " .. t)
  end

  -- Carry the source position on the table itself. `to_pandoc_attr` raises
  -- for a name pandoc cannot read back, but it is called later and elsewhere
  -- than `parse`, so relying on every consumer to rethread file/line across
  -- that gap loses the position exactly where the error needs it -- the two
  -- draft consumers in docs/plan.md (Tasks 5 and 7) already call
  -- `to_pandoc_attr(pending)` with no position, which would report
  -- `nil:nil: id "..." cannot be represented` to an author.
  local parsed = { id = nil, classes = {}, keyvals = {}, bare = {}, file = file, line = line }
  local seen_keys = {}

  for _, field in ipairs(split_fields(body)) do
    local f = trim(field)
    if f ~= "" then
      local key, value = f:match("^([%w%-_]+)%s*:%s*(.*)$")
      if key then
        value = unquote(trim(value))
        if seen_keys[key] then
          -- Markua spec, "Attribute Keys": "If a key is duplicated in an
          -- attribute list, the first key value is used and subsequent ones
          -- are ignored. A Markua Processor should add a warning in its list
          -- of warnings, which are *not* output in the output itself." This
          -- is a warning, not an error -- the document still has a defined
          -- meaning -- so the later value is dropped and the author is told.
          errors.warn(file, line, string.format("duplicate attribute key %q; first value kept", key), sink)
        elseif key == "class" then
          -- `class` is an ordinary attribute key, so the duplicate rule above
          -- governs it too: a repeated class: does not accumulate. The
          -- classes list exists for the `.name` shortcut, which is a
          -- different syntax.
          -- pandoc splits a class value on whitespace
          -- ("class" -> cs ++ T.words val in keyValAttr), so `{class: "tip
          -- wide"}` is two classes rather than one unrepresentable name.
          seen_keys[key] = true
          for word in value:gmatch("%S+") do
            parsed.classes[#parsed.classes + 1] = word
          end
        else
          seen_keys[key] = true
          parsed.keyvals[key] = value
        end
      elseif f:sub(1, 1) == "#" then
        -- Same first-wins rule; the spec asks for an error in the log rather
        -- than a warning for a duplicate id, but the value still resolves, so
        -- this reports without aborting.
        if parsed.id ~= nil then
          errors.warn(file, line, "duplicate id; first value kept", sink)
        else
          parsed.id = f:sub(2)
        end
      elseif f:sub(1, 1) == "." then
        parsed.classes[#parsed.classes + 1] = f:sub(2)
      else
        -- Neither key: value, #id, nor .class. This is not necessarily an
        -- error: `blurb`, `frontmatter`, and `/blurb` are all legitimate
        -- bare words whose meaning belongs to a later module (KTD5). A
        -- consumer that does not recognize this word names it in the hard
        -- error AGENTS.md requires; attributes.lua stays pure syntax and
        -- does not guess.
        parsed.bare[#parsed.bare + 1] = f
      end
    end
  end

  return parsed
end

-- Render a value for pandoc's attribute syntax, choosing the quote character
-- the way pandoc's keyValAttr can actually read back:
--
--   val <- enclosed (char '"')  (char '"')  litChar
--      <|> enclosed (char '\'') (char '\'') litChar
--      <|> ...
--
-- The reader's target format is markdown_strict plus extensions, which leaves
-- all_symbols_escapable OFF, so only original Markdown's escapable set works.
-- A backslash is in that set; a double quote is not. Verified against pandoc
-- 3.10.1 under that exact format: {title="He said \"hi\""} does not parse --
-- pandoc abandons the whole construct and renders the ::: delimiters as
-- literal paragraph text -- while {title='He said "hi"'} parses to the value
-- `He said "hi"`. Escaping the quote is what -f markdown accepts; measuring
-- the format actually handed to pandoc.read is what caught the difference.
--
-- So the quote character carries the value instead of an escape: single
-- quotes when it contains a double quote, double quotes otherwise. A value
-- containing both is unrepresentable here and is a hard error rather than
-- silent corruption.
local function escape_backslashes(v)
  return (v:gsub("\\", "\\\\"))
end

local function render_value(v, file, line)
  local has_double, has_single = v:find('"', 1, true), v:find("'", 1, true)
  if has_double and has_single then
    errors.raise(file, line,
      "attribute value carries both a single and a double quote, which pandoc's attribute syntax cannot express: " .. v)
  end
  local body = escape_backslashes(v)
  if has_double then
    return "'" .. body .. "'"
  end
  return '"' .. body .. '"'
end

-- An id or class has no escape syntax in pandoc's attribute block -- unlike a
-- value, which quotes and backslashes can always carry. The accepted shapes
-- are pandoc's own, from Readers/Markdown.hs:
--
--   identifierAttr = char '#' >> many1 (alphaNum <|> oneOf "-_:.")
--   identifier     = letter >> many (alphaNum <|> oneOf "-_:.")   -- class
--
-- So an id may start with a digit but a class may not, and neither may contain
-- anything else. Emitting a name outside that grammar does not merely lose the
-- name: pandoc rejects the *entire* attribute block and renders it as literal
-- text, so `{#a&b .3things}` leaks braces into the prose and drops every other
-- attribute with it -- the "never pass through as literal braces into the
-- output" failure AGENTS.md forbids. Verified against pandoc 3.10.1: `{#a&b}`,
-- `{#a%b}` and `{.3things}` all come back as literal Str, while `{#3things}`,
-- `{#a:b}`, `{#a.b}` and `{#caf\233}` parse.
--
-- Bytes >= 0x80 are accepted as name characters. pandoc's alphaNum is Unicode
-- aware, so `café` and CJK ids are legal there; matching that exactly would
-- mean a Unicode character-class table in pure Lua. Accepting the high range
-- errs toward passing real author text through rather than falsely rejecting
-- it, at the cost of not catching an exotic non-alphanumeric symbol.
local ID_PATTERN = "^[%w%-_:.\128-\255]+$"
local CLASS_PATTERN = "^[%a\128-\255][%w%-_:.\128-\255]*$"

--- Validate that `name` (an id or a class, per `kind`) can be represented in
--- a pandoc attribute block, raising unconditionally otherwise. Shared by
--- `to_pandoc_attr` below and by any other module that emits an id or class
--- pandoc did not itself derive -- blocks.lua's `open_div` is the other
--- caller, validating a Markua `id:`/`class:` value before it reaches the
--- literal `::: {...}` text this reader hands to pandoc.read.
function M.check_name(kind, name, file, line)
  local pattern = kind == "class" and CLASS_PATTERN or ID_PATTERN
  if not name:match(pattern) then
    errors.raise(file, line, string.format("%s %q cannot be represented in a pandoc attribute", kind, name))
  end
end

--- Render a parsed attribute list as a pandoc attribute block.
--- `file` and `line` are optional and only position the error raised when an
--- id or class cannot be represented.
function M.to_pandoc_attr(parsed, file, line)
  -- Fall back to the position parse recorded, so a caller that omits these
  -- still produces an error naming the author's file and line.
  file = file or parsed.file
  line = line or parsed.line
  local parts = {}
  if parsed.id then
    M.check_name("id", parsed.id, file, line)
    parts[#parts + 1] = "#" .. parsed.id
  end
  for _, c in ipairs(parsed.classes) do
    M.check_name("class", c, file, line)
    parts[#parts + 1] = "." .. c
  end
  -- Sorted keys are the determinism mechanism for R18: iterating pairs()
  -- directly would order keyvals by Lua's internal hash order, which is not
  -- guaranteed stable across runs.
  local keys = {}
  for k in pairs(parsed.keyvals) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s=%s", k, render_value(parsed.keyvals[k], file, line))
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/attributes_spec.lua`
Expected: PASS, 34 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/attributes.lua test/attributes_spec.lua
git commit -m "feat: Markua attribute-list parser"
```

---

## Phase 2: Block constructs

### Task 4: Config and class validation

**Files:**

- Create: `src/markua/config.lua`
- Test: `test/config_spec.lua`

**Interfaces:**

- Consumes: nothing
- Produces: `config.defaults() -> table` with `callout_classes` (array), `strict` (boolean), `index_keys` (array). `config.merge(base, overrides) -> table`. `config.load_file(path) -> table or nil, message`. `config.is_callout_class(cfg, name) -> boolean`.

The documented Markua class set includes `note`, but real Leanpub builds reject it, so books override this list. It must be data, not a hardcoded branch.

- [ ] **Step 1: Write the failing test**

Create `test/config_spec.lua`:

```lua
-- Spec for the reader configuration module (src/markua/config.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run with
-- `busted test/config_spec.lua` from the repo root -- require("src.markua.config")
-- resolves through .busted's lpath only from there.
--
-- The four `config` scenarios docs/plan.md Task 4 Step 1 specifies are here
-- verbatim in intent. Everything else covers what that draft leaves untested:
-- merge's immutability, load_file's sandbox, and the override validation this
-- plan adds.
local config = require("src.markua.config")

describe("config.defaults", function()
  it("ships the documented Markua class set", function()
    local cfg = config.defaults()
    assert.is_true(config.is_callout_class(cfg, "warning"))
    assert.is_true(config.is_callout_class(cfg, "discussion"))
    assert.is_false(config.is_callout_class(cfg, "nonsense"))
  end)

  -- Exact match, not substring: "notebook" must not inherit "note".
  it("matches a callout class exactly rather than by prefix", function()
    local cfg = config.defaults()
    assert.is_true(config.is_callout_class(cfg, "note"))
    assert.is_false(config.is_callout_class(cfg, "notebook"))
  end)

  it("accepts both index keys, spec form first", function()
    assert.same({ "ix", "i" }, config.defaults().index_keys)
  end)

  it("defaults to strict", function()
    assert.is_true(config.defaults().strict)
  end)

  -- KTD9: spec.txt:6895-6923 documents C> and {class: center} as a blurb
  -- class, and the shipped defaults omitted it -- both forms raised before
  -- U3. Pinned as its own scenario, deliberately, rather than folded
  -- silently into the exact-set assertion below.
  it("includes center in the documented class set (KTD9)", function()
    local cfg = config.defaults()
    assert.is_true(config.is_callout_class(cfg, "center"))
  end)

  -- The exact-set pin U3 adds: nine classes, not eight, now that center has
  -- joined them. Order-independent (table.sort both sides) because
  -- callout_classes's declaration order is not itself a documented contract.
  it("ships exactly the documented nine callout classes", function()
    local cfg = config.defaults()
    local expected = {
      "warning", "tip", "note", "information",
      "error", "question", "discussion", "exercise", "center",
    }
    table.sort(expected)
    local actual = {}
    for _, c in ipairs(cfg.callout_classes) do
      actual[#actual + 1] = c
    end
    table.sort(actual)
    assert.same(expected, actual)
  end)

  -- defaults() must build its tables per call. A shared array would let one
  -- book's override leak into the next document converted in the same process.
  it("returns independent tables on each call", function()
    local first, second = config.defaults(), config.defaults()
    first.callout_classes[#first.callout_classes + 1] = "leaked"
    assert.is_false(config.is_callout_class(second, "leaked"))
  end)
end)

describe("config.is_index_key", function()
  it("accepts both documented index keys", function()
    local cfg = config.defaults()
    assert.is_true(config.is_index_key(cfg, "ix"))
    assert.is_true(config.is_index_key(cfg, "i"))
  end)

  -- Exact match, not substring: "index" must not inherit "i" or "ix".
  it("matches an index key exactly rather than by prefix", function()
    local cfg = config.defaults()
    assert.is_false(config.is_index_key(cfg, "index"))
  end)
end)

describe("config.merge", function()
  it("lets a book override the class list", function()
    local cfg = config.merge(config.defaults(), { callout_classes = { "tip" } })
    assert.is_true(config.is_callout_class(cfg, "tip"))
    assert.is_false(config.is_callout_class(cfg, "note"))
  end)

  -- An override replaces outright rather than accumulating: narrowing the
  -- documented eight is the whole point, so appending would defeat it.
  it("replaces a value rather than merging into it", function()
    local cfg = config.merge(config.defaults(), { index_keys = { "ix" } })
    assert.same({ "ix" }, cfg.index_keys)
  end)

  it("does not mutate the base it was given", function()
    local base = config.defaults()
    config.merge(base, { strict = false })
    assert.is_true(base.strict)
  end)

  -- assert.same is deep equality, so it passes even when the two configs are
  -- the SAME table. Identity is what matters here: a consumer appending to one
  -- config's array must not write through into the base every other config is
  -- derived from.
  it("returns arrays that are not the base's arrays", function()
    local base = config.defaults()
    local cfg = config.merge(base, { index_keys = { "ix" } })
    assert.is_false(cfg.callout_classes == base.callout_classes)
    table.insert(cfg.callout_classes, "leaked")
    assert.is_false(config.is_callout_class(base, "leaked"))
  end)

  it("keeps sibling configs derived from one base independent", function()
    local base = config.defaults()
    local first = config.merge(base, { index_keys = { "ix" } })
    local second = config.merge(base, { index_keys = { "i" } })
    table.insert(first.callout_classes, "leaked")
    assert.is_false(config.is_callout_class(second, "leaked"))
  end)

  it("copies the base when there is nothing to override", function()
    local base = config.defaults()
    local cfg = config.merge(base, nil)
    assert.same(base.callout_classes, cfg.callout_classes)
    assert.is_true(cfg.strict)
  end)
end)

-- Fixture config files are written at run time rather than committed. The
-- sandbox scenarios need hostile content that has no business sitting in the
-- repo, and a spec that builds its own inputs cannot drift from them.
local fixtures = {}

local function write_fixture(contents, mode)
  local path = os.tmpname()
  local handle = assert(io.open(path, mode or "w"))
  handle:write(contents)
  handle:close()
  fixtures[#fixtures + 1] = path
  return path
end

-- A path guaranteed not to exist: os.tmpname creates the file on POSIX, so
-- removing it yields a name nothing else will claim.
local function missing_path()
  local path = os.tmpname()
  os.remove(path)
  return path
end

describe("config.load_file", function()
  -- Unconditional cleanup: an assertion that fails mid-scenario skips any
  -- inline os.remove, which would leak fixtures into /tmp across CI runs.
  after_each(function()
    for _, path in ipairs(fixtures) do
      os.remove(path)
    end
    fixtures = {}
  end)

  it("loads a table from a config file", function()
    local path = write_fixture([[return { callout_classes = { "tip" } }]])
    local overrides = config.load_file(path)
    assert.same({ "tip" }, overrides.callout_classes)
  end)

  it("reports a missing file by path instead of raising", function()
    local path = missing_path()
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.truthy(err:find(path, 1, true))
  end)

  it("reports a syntax error by path instead of raising", function()
    local path = write_fixture([[return { callout_classes = ]])
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.truthy(err:find(path, 1, true))
  end)

  it("rejects a chunk that returns something other than a table", function()
    local path = write_fixture([[return 42]])
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.truthy(err:find("table", 1, true))
  end)

  -- The empty environment is the sandbox: a config file is evaluated for its
  -- return value, not run as a program with library access.
  it("denies a config file the os library", function()
    local path = write_fixture([[os.execute("touch /tmp/markua-pwned") return {}]])
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.truthy(err:find("os", 1, true))
  end)

  it("denies a config file require", function()
    local path = write_fixture([[require("io") return {}]])
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.truthy(err:find("require", 1, true))
  end)

  -- An override the reader does not recognize is a hard error, not a silent
  -- no-op. A typo that changes nothing gives the author no signal at all.
  describe("override validation", function()
    it("rejects an unrecognized key by name", function()
      local path = write_fixture([[return { callout_class = { "tip" } }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find('"callout_class"', 1, true))
    end)

    -- strict has its own channel. Reader() applies --lenient before it merges
    -- the config file, so a file setting strict would silently cancel the flag
    -- the user just passed. Point the author at the flag instead.
    it("rejects strict and names the flag that sets it", function()
      local path = write_fixture([[return { strict = false }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("--lenient", 1, true))
    end)

    it("rejects a recognized key that is not a table", function()
      local path = write_fixture([[return { callout_classes = "tip" }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("callout_classes", 1, true))
      assert.truthy(err:find("array of strings", 1, true))
    end)

    -- Element types are checked, not just the outer table: a list of numbers
    -- would pass a bare type() check and then fail far away, inside a lookup.
    it("rejects non-string entries inside a recognized key", function()
      local path = write_fixture([[return { index_keys = { 1, 2 } }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("index_keys", 1, true))
      assert.truthy(err:find("array of strings", 1, true))
    end)

    -- The plausible author mistake: returning the class list itself rather
    -- than a table naming which key it overrides.
    it("rejects a bare list with no key names", function()
      local path = write_fixture([[return { "tip", "warning" }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("name the keys", 1, true))
    end)

    -- A table with a hole plus a stray key can make the pairs count equal `#`,
    -- at which point ipairs stops at the hole and an element check that trusts
    -- it never runs. Accepting this silently disabled every callout class.
    it("rejects an array with a hole in it", function()
      local path = write_fixture([[
        local t = {}
        for i = 1, 6 do t[i] = "c" .. i end
        t[1] = nil
        t.junk = "x"
        return { callout_classes = t }
      ]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("array of strings", 1, true))
    end)

    it("rejects a map-shaped value on a recognized key", function()
      local path = write_fixture([[return { callout_classes = { warning = true } }]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find("array of strings", 1, true))
    end)

    -- Several problems in one file must always report the alphabetically first,
    -- so the message does not move between runs. Lua seeds its string hash per
    -- state, so pairs() order can differ across processes; a spread of keys
    -- makes an unsorted implementation likely -- not certain -- to name a
    -- different one. This narrows the gap rather than closing it: within a
    -- single process pairs() is stable, so no in-process test can fully pin
    -- the sort.
    it("names the alphabetically first problem when a file has several", function()
      local path = write_fixture([[
        return { hhh = {}, ggg = {}, fff = {}, eee = {},
                 ddd = {}, ccc = {}, bbb = {}, aaa = {} }
      ]])
      local overrides, err = config.load_file(path)
      assert.is_nil(overrides)
      assert.truthy(err:find('"aaa"', 1, true))
    end)

    it("accepts a config that overrides nothing", function()
      local path = write_fixture([[return {}]])
      assert.same({}, config.load_file(path))
    end)

    it("accepts a partial override", function()
      local path = write_fixture([[return { callout_classes = { "tip" } }]])
      assert.same({ "tip" }, config.load_file(path).callout_classes)
    end)

    it("accepts both recognized keys together", function()
      local path = write_fixture([[return { callout_classes = { "tip" }, index_keys = { "ix" } }]])
      local overrides = config.load_file(path)
      assert.same({ "tip" }, overrides.callout_classes)
      assert.same({ "ix" }, overrides.index_keys)
    end)
  end)

  -- Text mode only. Precompiled bytecode skips the parser entirely and is not
  -- something an author writes by hand, so refusing it costs nothing.
  it("refuses precompiled bytecode", function()
    local path = write_fixture(string.dump(load([[return { callout_classes = { "tip" } }]])), "wb")
    local overrides, err = config.load_file(path)
    assert.is_nil(overrides)
    assert.is_string(err)
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/config_spec.lua`
Expected: FAIL with "module 'src.markua.config' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/config.lua`:

```lua
--- Reader configuration: documented defaults and book-level overrides.
--
-- Pure data plus the lookups the rest of the pipeline needs. No pandoc global
-- here, per AGENTS.md -- busted runs under system Lua, where it does not exist.
--
-- A book narrows the documented class list through a `--config` file, which
-- `load_file` reads as data rather than running as a program.
--
-- The shape this module defines is already load-bearing: the shipped
-- `errors.report` reads `cfg.strict` and `cfg.sink`. Later tasks add the rest
-- of the consumers -- blocks.lua asking `is_callout_class`, inline.lua
-- iterating `index_keys`, and Reader() calling `load_file` then `merge`.
local M = {}

--- The reader's built-in configuration. Constructs fresh tables per call, so
--- one document's override cannot leak into the next one converted in the same
--- process.
function M.defaults()
  return {
    -- The documented Markua 0.30 set. Leanpub itself rejects `note` in some
    -- builds and individual books narrow the list further, which is exactly
    -- why this is data a config file can replace rather than a branch.
    -- `center` (spec.txt:6895-6923, KTD9) is the class the `C>` sugar prefix
    -- and `{class: center}` both name -- without it here, both forms raise.
    callout_classes = {
      "warning", "tip", "note", "information",
      "error", "question", "discussion", "exercise", "center",
    },
    -- `ix` is the spec form; `i` is a widespread real-world variant that real
    -- manuscripts use, so both are recognized.
    index_keys = { "ix", "i" },
    -- Strict is the default; `--lenient` is the only thing that lowers it.
    strict = true,
  }
end

--- Combine `overrides` onto `base`, returning a new table.
--
-- Shallow by design: `callout_classes = {"tip"}` must narrow the documented
-- set to exactly `tip`, so a value replaces rather than accumulates.
-- Neither argument is mutated -- callers hold onto `defaults()` results and a
-- merge that wrote through would corrupt them.
function M.merge(base, overrides)
  local out = {}
  for k, v in pairs(base) do
    out[k] = v
  end
  for k, v in pairs(overrides or {}) do
    out[k] = v
  end
  -- Copy the table-valued fields so the result shares no table identity with
  -- its inputs. Without this, an un-overridden `callout_classes` is literally
  -- the base's table, and a consumer appending to one merged config writes
  -- through into the base and into every sibling merged from it -- the leak
  -- `defaults()` builds fresh tables to prevent, reintroduced one level down.
  -- This copies one level and stays a replace, not a deep merge: nested
  -- content is never combined, only detached.
  for k, v in pairs(out) do
    if type(v) == "table" then
      local copy = {}
      for item_key, item in pairs(v) do
        copy[item_key] = item
      end
      out[k] = copy
    end
  end
  return out
end

-- What a config file may set, and the shape each key carries. A table rather
-- than a branch chain, matching how scanner.lua holds its fence patterns: the
-- recognized set is data, so adding a key is a one-line change here.
local RECOGNIZED_KEYS = {
  callout_classes = "array of strings",
  index_keys = "array of strings",
}

-- Keys that reach cfg through some other channel, with the channel named. An
-- author who guesses the config file deserves the right answer, not a bare
-- "unrecognized" -- and silently accepting `strict` would be worse still,
-- because Reader() applies --lenient before merging the file, so the file
-- would quietly cancel the flag the user just passed.
local REDIRECTED_KEYS = {
  strict = "set it with --lenient rather than a config file",
}

-- Both recognized keys carry the same shape, so one predicate covers both,
-- elements included. A bare type() check would pass `{1, 2}` and fail later
-- inside a lookup, far from the config file that caused it.
--
-- Counting keys and then indexing 1..count is deliberate. Neither `#` nor
-- `ipairs` can carry this check: `#` is only defined at a border, so a table
-- with a hole plus a stray key can make `#value` equal the key count, and
-- `ipairs` then stops at the hole and validates nothing. That combination
-- accepted a config whose callout_classes had a gap, and every callout class
-- in the book silently stopped resolving. Indexing every slot from 1 to the
-- key count catches holes, extra hash keys, and non-string elements alike.
local function is_array_of_strings(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  for i = 1, count do
    if type(value[i]) ~= "string" then
      return false
    end
  end
  return true
end

-- Reject anything the reader would otherwise ignore. Keys are sorted so a file
-- with more than one problem reports the same one every run; pairs() order is
-- not stable, and an error message that moves between runs is a bad bug report.
local function validate(overrides, path)
  local keys = {}
  for key in pairs(overrides) do
    if type(key) ~= "string" then
      return nil, string.format("config %s must name the keys it overrides, not be a bare list", path)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local redirect = REDIRECTED_KEYS[key]
    if redirect then
      return nil, string.format("config %s sets %q: %s", path, key, redirect)
    end
    local expected = RECOGNIZED_KEYS[key]
    if not expected then
      return nil, string.format("config %s sets unrecognized key %q", path, key)
    end
    if not is_array_of_strings(overrides[key]) then
      return nil, string.format("config %s: %q must be an %s", path, key, expected)
    end
  end
  return overrides
end

--- Load a book-level override file: a Lua chunk returning a table.
--
-- Lua source rather than JSON keeps this module dependency-free and pure, so
-- busted can exercise it under system Lua with no pandoc and no JSON library.
--
-- The chunk is loaded with an empty environment, so a config file is data: it
-- cannot reach the filesystem, spawn a process, or `require` anything, because
-- none of those names resolve. Mode "t" refuses precompiled bytecode, which no
-- author writes by hand and which would skip the parser entirely.
--
-- This is not a defense against resource exhaustion, and is not meant to be:
-- concatenation and `for` are VM primitives that need no globals, so a config
-- file can still allocate without bound. The premise that makes that
-- acceptable is that the file is the author's own -- it stops holding if
-- `--config` is ever pointed at content an outside contributor can influence.
--
-- Returns nil plus a message on any failure rather than raising, so the caller
-- decides whether a bad config is fatal. Reader() in src/markua.lua is that
-- caller and turns it into an error.
function M.load_file(path)
  local chunk, err = loadfile(path, "t", {})
  if not chunk then
    return nil, "cannot load config " .. path .. ": " .. tostring(err)
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, "error in config " .. path .. ": " .. tostring(result)
  end
  if type(result) ~= "table" then
    return nil, "config " .. path .. " must return a table"
  end
  return validate(result, path)
end

--- Is `name` one of the configured callout classes?
--
-- A linear scan over a single-digit list. Building a set would cost more in
-- allocation than it saves in lookups at this size, and unlike `errors.report`
-- this is not the error path, so it does not defend against a malformed cfg:
-- validation happens once, at the config-file boundary.
function M.is_callout_class(cfg, name)
  for _, c in ipairs(cfg.callout_classes) do
    if c == name then
      return true
    end
  end
  return false
end

--- Is `key` one of the configured index keys (`ix`, `i`, and whatever a book
--- adds)?
--
-- Same linear scan as `is_callout_class` above, against `cfg.index_keys`
-- instead of `cfg.callout_classes` -- both lists are single digits long, so a
-- set would cost more in allocation than it saves in lookups here.
function M.is_index_key(cfg, key)
  for _, k in ipairs(cfg.index_keys) do
    if k == key then
      return true
    end
  end
  return false
end

return M
```

A config file is therefore a small Lua table, and the override path documented
in the Global Constraints is real end to end:

```lua
-- markua.config.lua -- this book's Leanpub build rejects `note`.
return {
  callout_classes = { "warning", "tip", "information", "error", "discussion" },
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/config_spec.lua`
Expected: PASS, 29 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/config.lua test/config_spec.lua
git commit -m "feat: reader config with overridable callout classes"
```

---

### Task 5: Blurbs, asides, and matter directives

**Files:**

- Create: `src/markua/blocks.lua`
- Test: `test/blocks_spec.lua`

**Interfaces:**

- Consumes: `scanner`, `attributes`, `config`, `errors`
- Produces: `blocks.transform(lines, cfg, file) -> array of strings`. Input is scanner records; output is pandoc-markdown lines. Blurbs accept three syntaxes — a class-bearing attribute list above a `B>` run, the eight sugar prefixes `C/D/E/I/Q/T/W/X>` with their own implied class, and the fenced `{blurb, class: X}` … `{/blurb}` form — all producing the same fenced div, with the callout class heading the class list, any decorative classes riding between it and the marker, and `.blurb` last (`::: {.tip .wide .blurb}`). Asides accept two syntaxes — an `A>` run and the fenced `{aside}` … `{/aside}` form — sharing the same head-class-then-marker shape with `.aside` last in place of `.blurb`. Structural directives (`frontmatter`, `mainmatter`, `backmatter`) and insertion directives (`pagebreak`, the title/front-matter inserts, `toc`, `figures`, `tables`, `index`, `exercise-answers`, `quiz-answers`) both lower to self-closing marker pairs — `::: {.matter matter="word"}` and `::: {.insert insert="word"}` respectively — carrying the bare word verbatim in both the class and the attribute value, so there is no mapping table to drift. `{class: part}` attaches to the following heading.

- [ ] **Step 1: Write the failing test**

Create `test/blocks_spec.lua`:

```lua
-- Spec for the block-construct pass (src/markua/blocks.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run with
-- `busted test/blocks_spec.lua` from the repo root -- require("src.markua.blocks")
-- resolves through .busted's lpath only from there.
--
-- The first describe block below covers the pass skeleton and the pending
-- attribute-list lifecycle: fence passthrough, the {class: part} heading
-- attach, the index-only passthrough, and every path an unclaimed attribute
-- list can take out of the pending state. Blurbs, the sugar prefixes, asides,
-- and the bare-word directive table each have their own describe block below
-- this one; a bare word none of THEM recognizes -- {nonsense}, covered under
-- directives -- is what exercises this pass's generic "unclaimed attribute
-- list" fallback instead of a construct-specific marker.
local scanner = require("src.markua.scanner")
local config = require("src.markua.config")
local blocks = require("src.markua.blocks")

-- A sink that swallows errors.warn's output so a lenient-mode test does not
-- spew "warning: ..." over the test run's own output.
local function quiet_sink()
  return { write = function() end }
end

-- A sink that records errors.warn's output instead of swallowing it, for the
-- scenario that must observe KTD10a's warning-on-override rather than
-- merely not crash on it.
local function capturing_sink()
  local sink = { writes = {} }
  sink.write = function(self, ...)
    local parts = {}
    for _, v in ipairs({ ... }) do
      parts[#parts + 1] = tostring(v)
    end
    table.insert(self.writes, table.concat(parts))
  end
  return sink
end

local function lenient_cfg()
  return config.merge(config.defaults(), { strict = false, sink = quiet_sink() })
end

-- Most scenarios only need the joined text; the lenient-position scenarios
-- need the raw array so they can assert an exact output INDEX rather than a
-- substring's mere presence within one giant string.
local function run_lines(text, cfg)
  return blocks.transform(scanner.scan(text), cfg or config.defaults(), "f.md")
end

local function run(text, cfg)
  return table.concat(run_lines(text, cfg), "\n")
end

describe("blocks.transform", function()
  it("attaches {class: part} to the following heading", function()
    local out = run("{class: part}\n# Foundations\n")
    assert.is_truthy(out:find("# Foundations {.part}", 1, true))
  end)

  it("never transforms a JSON code block containing an attribute-shaped line", function()
    local out = run('```json\n{"class": "tip"}\n```\n')
    assert.is_truthy(out:find('{"class": "tip"}', 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("never transforms B> or {/blurb} inside a code fence", function()
    local out = run("```markua\nB> not a blurb\n{/blurb}\n```\n")
    assert.is_truthy(out:find("B> not a blurb", 1, true))
    assert.is_truthy(out:find("{/blurb}", 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("rejects an attribute list that precedes a plain paragraph", function()
    local ok, err = pcall(run, "{class: tip}\nJust a paragraph.\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("{class: tip}", 1, true))
  end)

  it("rejects an attribute list separated from a B> run by a blank line", function()
    -- A blank line disqualifies a pending attribute list before it reaches
    -- the B> branch below (KTD6) -- the rejection must fire on the blank
    -- itself, not survive across it to (wrongly) attach to the run that
    -- follows.
    local ok = pcall(run, "{class: tip}\n\nB> hi\n")
    assert.is_false(ok)
  end)

  it("rejects an attribute list left unconsumed at end of input", function()
    local ok = pcall(run, "Some intro text.\n\n{class: tip}")
    assert.is_false(ok)
  end)

  it("rejects a second attribute list that would shadow the first", function()
    local ok = pcall(run, '{title: "x"}\n{class: tip}\nB> hello\n')
    assert.is_false(ok)
  end)

  it("passes a standalone index line through untouched, not as a pending list", function()
    -- inline.transform runs after this pass and owns index markers. Claiming
    -- it here would render {ix: "B-tree"} as visible text in the book.
    local out = run('{ix: "B-tree"}\n\nB-trees are fast.\n')
    assert.is_truthy(out:find('{ix: "B-tree"}', 1, true))
  end)

  it("re-emits a rejected attribute list before any line that followed it, under --lenient", function()
    local lines = run_lines("{class: tip}\n\nJust a paragraph.\n", lenient_cfg())
    local pending_index, paragraph_index
    for idx, line in ipairs(lines) do
      if line == "{class: tip}" then
        pending_index = idx
      elseif line == "Just a paragraph." then
        paragraph_index = idx
      end
    end
    assert.is_truthy(pending_index)
    assert.is_truthy(paragraph_index)
    assert.is_true(pending_index < paragraph_index)
  end)

  it("places a rejected attribute list before the directive marker that follows it, under --lenient", function()
    -- {pagebreak} is a recognized directive, so it does not fall through the
    -- unclaimed-attribute-list path itself -- it opens its own self-closing
    -- marker. What this pins down is ORDER: the pending {class: tip} list
    -- must be re-emitted BEFORE that marker, not after it.
    local lines = run_lines("{class: tip}\n{pagebreak}\n", lenient_cfg())
    local tip_index, marker_index
    for idx, line in ipairs(lines) do
      if line == "{class: tip}" then
        tip_index = idx
      elseif line:find('insert="pagebreak"', 1, true) then
        marker_index = idx
      end
    end
    assert.is_truthy(tip_index)
    assert.is_truthy(marker_index)
    assert.is_true(tip_index < marker_index)
  end)

  it("raises in strict mode when an attribute list precedes a directive line", function()
    -- A directive line does not consume a pending list.
    local ok = pcall(run, "{class: tip}\n{pagebreak}\n")
    assert.is_false(ok)
  end)

  it("raises in strict mode when an attribute list precedes a fenced {blurb} opener", function()
    -- Per R13a, a preceding list is illegal above a fenced {blurb} opener --
    -- the {blurb} branch rejects it before opening the div, so the hard
    -- error the author sees comes from that branch, not the generic
    -- unclaimed-attribute-list fallback.
    local ok = pcall(run, "{class: tip}\n{blurb, class: warning}\n")
    assert.is_false(ok)
  end)

  it("escapes a standalone ::: body line so it cannot close a fence this pass opened", function()
    local out = run(":::\n")
    assert.is_truthy(out:find("\\:::", 1, true))
  end)

  it("escapes a standalone $$ body line the same way", function()
    local out = run("$$\n")
    assert.is_truthy(out:find("\\$$", 1, true))
  end)
end)

-- B> runs and the fenced {blurb} ... {/blurb} form, both syntaxes
-- producing the identical div per R3.
describe("blocks.transform blurbs", function()
  it("converts {class: tip} above a B> run into a fenced div", function()
    local out = run("{class: tip}\nB> Press Ctrl-R.\n")
    assert.is_truthy(out:find("::: {.tip .blurb}", 1, true))
    assert.is_truthy(out:find("Press Ctrl%-R%."))
    assert.is_truthy(out:find(":::", 1, true))
  end)

  it("puts the callout class ahead of the .blurb marker", function()
    -- Load-bearing, not cosmetic (see the comment on open_div in blocks.lua):
    -- pandoc's DocBook writer matches only the head of the class list.
    local out = run("{class: tip}\nB> hi\n")
    local blurb_at = out:find("::: {.tip .blurb}", 1, true)
    assert.is_truthy(blurb_at)
    -- ".blurb" must not appear before ".tip" anywhere in that same marker.
    assert.is_nil(out:find("::: {.blurb .tip}", 1, true))
  end)

  it("converts the fenced {blurb, class: X} ... {/blurb} form identically", function()
    local out = run("{blurb, class: warning}\nBack up first.\n{/blurb}\n")
    assert.is_truthy(out:find("::: {.warning .blurb}", 1, true))
    assert.is_truthy(out:find("Back up first.", 1, true))
  end)

  it("defaults a B> run with no pending attribute list to information", function()
    local out = run("B> hi\n")
    assert.is_truthy(out:find("::: {.information .blurb}", 1, true))
  end)

  it("carries a decorative class alongside the callout class, marker last", function()
    -- attributes.parse splits one class: value on whitespace (KTD10b), so
    -- {class: "tip wide"} arrives as classes = {"tip", "wide"} -- not a
    -- per-class shorthand. The registered class heads the list, the
    -- decorative one survives between it and the marker.
    local out = run('{class: "tip wide"}\nB> hi\n')
    assert.is_truthy(out:find("::: {.tip .wide .blurb}", 1, true))
  end)

  it("raises on an unregistered callout class, naming the offender", function()
    local ok, err = pcall(run, "{class: bogus}\nB> hi\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("bogus", 1, true))
  end)

  it("downgrades an unregistered callout class under --lenient, keeping the author's class", function()
    -- AGENTS.md makes --lenient downgrade a hard error to a warning, and an
    -- unregistered class is one. Without this the flag could recover from an
    -- unclaimed attribute list but not from a bad class -- and a class this
    -- book's list rejects is exactly what --lenient exists to triage, since
    -- real Leanpub builds reject `note` and books narrow the set further.
    local out = table.concat(blocks.transform(
      scanner.scan("{class: bogus}\nB> hi\n"), lenient_cfg(), "f.md"), "\n")
    assert.is_truthy(out:find("::: {.bogus .blurb}", 1, true))
    assert.is_truthy(out:find("hi", 1, true))
  end)

  it("names the known spelling when only letter case differs (KTD8)", function()
    local ok, err = pcall(run, "{class: Tip}\nB> hi\n")
    assert.is_false(ok)
    local msg = tostring(err)
    assert.is_truthy(msg:find("Tip", 1, true))
    assert.is_truthy(msg:find("tip", 1, true))
  end)

  it("raises on an unclosed {blurb}, naming the opening line", function()
    local ok, err = pcall(run, "{blurb, class: tip}\nnever closes\n")
    assert.is_false(ok)
    local msg = tostring(err)
    assert.is_truthy(msg:find("unclosed", 1, true))
    assert.is_truthy(msg:find("f.md:1", 1, true))
  end)

  it("does not let a {/blurb} inside a fenced code block close the blurb", function()
    local out = run("{blurb, class: tip}\n```\n{/blurb}\n```\nreal end\n{/blurb}\n")
    local _, count = out:gsub(":::", "")
    assert.equals(2, count)  -- only the real opener and the real closer
    assert.is_truthy(out:find("real end", 1, true))
  end)

  it("escapes a ::: body line inside a B> run", function()
    local out = run("{class: tip}\nB> before\nB> :::\nB> after\n")
    assert.is_truthy(out:find("\\:::", 1, true))
  end)

  it("does not let a second B> run inherit an earlier run's class", function()
    local out = run("{class: tip}\nB> first\n\nB> second\n")
    assert.is_truthy(out:find("::: {.tip .blurb}", 1, true))
    assert.is_truthy(out:find("::: {.information .blurb}", 1, true))
  end)

  it("rejects a decorative class pandoc's attribute syntax cannot represent, naming it", function()
    -- attributes.check_name rejects a class starting with a digit
    -- (CLASS_PATTERN requires a leading letter). Without this check, open_div
    -- would emit "::: {.tip .3bad .blurb}" verbatim, and pandoc rejects the
    -- WHOLE attribute block on the illegal class -- destroying the blurb and
    -- leaking literal braces into the finished book.
    local ok, err = pcall(run, '{class: "tip 3bad"}\nB> hi\n')
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("3bad", 1, true))
  end)

  it("rejects an id pandoc's attribute syntax cannot represent, naming it", function()
    -- ID_PATTERN has no allowance for whitespace, so a pending list's
    -- id: carrying a space must be rejected the same way an invalid class
    -- is, before it reaches the div's attribute block.
    local ok, err = pcall(run, '{id: "bad id"}\nT> hi\n')
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("bad id", 1, true))
  end)
end)

-- A> runs and the fenced {aside} ... {/aside} form. A bare aside has no
-- callout-class default (unlike a blurb's `information`, R4); a pending
-- attribute list above an A> run is APPLIED, not dropped (KTD7), while one
-- above a fenced opener raises (R13a), mirroring the blurb prohibition.
describe("blocks.transform asides", function()
  it("converts an A> run with no pending attribute list into a bare aside div", function()
    local out = run("A> ### Why\nA>\nA> Because.\n")
    assert.is_truthy(out:find("::: {.aside}", 1, true))
    assert.is_truthy(out:find("### Why", 1, true))
    assert.is_truthy(out:find("Because.", 1, true))
  end)

  it("converts the fenced {aside} ... {/aside} form into the identical bare div", function()
    local out = run("{aside}\nSome side note.\n{/aside}\n")
    assert.is_truthy(out:find("::: {.aside}", 1, true))
    assert.is_truthy(out:find("Some side note.", 1, true))
  end)

  it("raises on an unclosed {aside}, naming the opening line", function()
    local ok, err = pcall(run, "{aside}\nnever closes\n")
    assert.is_false(ok)
    local msg = tostring(err)
    assert.is_truthy(msg:find("unclosed", 1, true))
    assert.is_truthy(msg:find("f.md:1", 1, true))
  end)

  it("applies a pending attribute list above an A> run instead of dropping it", function()
    local out = run("{class: tip}\nA> hi\n")
    assert.is_truthy(out:find("::: {.tip .aside}", 1, true))
  end)

  it("raises on an unregistered callout class above an A> run, naming the offender", function()
    local ok, err = pcall(run, "{class: bogus}\nA> hi\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("bogus", 1, true))
  end)

  it("resolves inline attributes on a fenced {aside} opener like a fenced blurb's", function()
    local out = run("{aside, class: tip}\nhi\n{/aside}\n")
    assert.is_truthy(out:find("::: {.tip .aside}", 1, true))
  end)

  it("raises when an attribute list precedes a fenced {aside} opener (R13a)", function()
    local ok = pcall(run, "{class: tip}\n{aside}\nhi\n{/aside}\n")
    assert.is_false(ok)
  end)

  it("does not let a {/aside} inside a fenced code block close the aside", function()
    local out = run("{aside}\n```\n{/aside}\n```\nreal end\n{/aside}\n")
    local _, count = out:gsub(":::", "")
    assert.equals(2, count)  -- only the real opener and the real closer
    assert.is_truthy(out:find("real end", 1, true))
  end)

  it("never transforms an A> line inside a fenced code block", function()
    local out = run("```markua\nA> not an aside\n```\n")
    assert.is_truthy(out:find("A> not an aside", 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)
end)

-- The eight documented syntactic-sugar blurb prefixes (C/D/E/I/Q/T/W/X>)
-- open blurbs of their specified class instead of passing through as literal
-- prose (R5). B> stays the no-implied-class case. KTD10a governs precedence
-- when a pending attribute list disagrees with a prefix's implied class: the
-- explicit class wins and the conversion still succeeds, with a warning to
-- the sink so the author learns the two signals disagree (R5a).
describe("blocks.transform blurb sugar prefixes", function()
  local prefix_classes = {
    C = "center",
    D = "discussion",
    E = "error",
    I = "information",
    Q = "question",
    T = "tip",
    W = "warning",
    X = "exercise",
  }

  for letter, class in pairs(prefix_classes) do
    it("opens a " .. class .. " blurb for the " .. letter .. "> prefix", function()
      local out = run(letter .. "> hi\n")
      assert.is_truthy(out:find("::: {." .. class .. " .blurb}", 1, true))
    end)
  end

  it("collects every line of a multi-line T> run into one div", function()
    local out = run("T> line one\nT> line two\n")
    assert.is_truthy(out:find("::: {.tip .blurb}", 1, true))
    assert.is_truthy(out:find("line one", 1, true))
    assert.is_truthy(out:find("line two", 1, true))
    local _, count = out:gsub(":::", "")
    assert.equals(2, count)  -- exactly one opener and one closer
  end)

  it("renders C> and {class: center} above a B> run identically", function()
    local sugar = run("C> hi\n")
    local spelled_out = run("{class: center}\nB> hi\n")
    assert.equals(sugar, spelled_out)
  end)

  it("does not transform a sugar prefix inside a fenced code block", function()
    local out = run("```markua\nT> not a tip\n```\n")
    assert.is_truthy(out:find("T> not a tip", 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("lets an explicit {class: X} above a sugar prefix override its implied class", function()
    -- The spec's own worked example: {class: tip} above W> renders as a tip
    -- blurb, not a failed conversion. The warning this also emits (R5a) is
    -- covered by its own scenario below; quiet it here so it does not spew
    -- over this run's output.
    local out = run("{class: tip}\nW> hi\n", config.merge(config.defaults(), { sink = quiet_sink() }))
    assert.is_truthy(out:find("::: {.tip .blurb}", 1, true))
  end)

  it("emits a warning when an explicit class overrides a sugar prefix's implied class", function()
    local sink = capturing_sink()
    local cfg = config.merge(config.defaults(), { sink = sink })
    run("{class: tip}\nW> hi\n", cfg)
    assert.is_true(#sink.writes > 0)
  end)

  it("adds only the decorative class, with no warning, when the explicit class agrees with the prefix", function()
    local sink = capturing_sink()
    local cfg = config.merge(config.defaults(), { sink = sink })
    local out = run('{class: "tip wide"}\nT> hi\n', cfg)
    assert.is_truthy(out:find("::: {.tip .wide .blurb}", 1, true))
    assert.equals(0, #sink.writes)
  end)

  it("carries an {id: sidebar} pending list's id onto a sugar prefix's div, keeping its class", function()
    -- A list with no class overrides nothing: `tip` still comes from the
    -- prefix, but the id rides along.
    local out = run("{id: sidebar}\nT> hi\n")
    assert.is_truthy(out:find("::: {#sidebar .tip .blurb}", 1, true))
  end)
end)

-- The closed set of fifteen Markua 0.30 bare-word directives, each
-- lowering to a self-closing marker rather than a wrapping pair (R16, R17).
-- `frontmatter` rides the `.matter` family alongside `mainmatter` and
-- `backmatter` even though the spec says the directive "does not exist"
-- (KTD5); `pagebreak` rides `.insert` alongside the front- and back-matter
-- insertion directives (KTD4). A bare word outside this table still exercises
-- the generic unclaimed-attribute-list fallback and raises, naming the word.
describe("blocks.transform directives", function()
  it("emits ::: {.matter matter=\"frontmatter\"} for {frontmatter}, word verbatim", function()
    local out = run("{frontmatter}\n")
    assert.is_truthy(out:find('::: {.matter matter="frontmatter"}', 1, true))
    assert.is_truthy(out:find(":::\n", 1, true) or out:find(":::$"))
  end)

  it("emits the matter marker for {mainmatter}", function()
    local out = run("{mainmatter}\n")
    assert.is_truthy(out:find('::: {.matter matter="mainmatter"}', 1, true))
  end)

  it("emits the matter marker for {backmatter}", function()
    local out = run("{backmatter}\n")
    assert.is_truthy(out:find('::: {.matter matter="backmatter"}', 1, true))
  end)

  it("emits ::: {.insert insert=\"index\"} for {index}", function()
    local out = run("{index}\n")
    assert.is_truthy(out:find('::: {.insert insert="index"}', 1, true))
  end)

  local insertion_words = {
    "half-title", "series-title", "title-page", "copyright", "dedication",
    "epigraph", "toc", "figures", "tables", "exercise-answers",
    "quiz-answers", "pagebreak",
  }
  for _, word in ipairs(insertion_words) do
    it("emits its own .insert marker for {" .. word .. "}, word verbatim", function()
      local out = run("{" .. word .. "}\n")
      assert.is_truthy(out:find('::: {.insert insert="' .. word .. '"}', 1, true))
    end)
  end

  it("emits a self-closing marker, not a wrapper: prose after {index} lands outside the div", function()
    local lines = run_lines("{index}\n\nProse here.\n")
    local open_idx, close_idx, prose_idx
    for idx, line in ipairs(lines) do
      if line == '::: {.insert insert="index"}' then
        open_idx = idx
      elseif line == ":::" and open_idx and not close_idx then
        close_idx = idx
      elseif line == "Prose here." then
        prose_idx = idx
      end
    end
    assert.is_truthy(open_idx)
    assert.is_truthy(close_idx)
    assert.is_truthy(prose_idx)
    -- The closer immediately follows the opener -- nothing is nested inside.
    assert.equals(open_idx + 1, close_idx)
    assert.is_true(prose_idx > close_idx)
  end)

  it("raises on an unrecognized bare word, naming the offender and the real fault", function()
    local ok, err = pcall(run, "{nonsense}\n")
    assert.is_false(ok)
    local msg = tostring(err)
    assert.is_truthy(msg:find("nonsense", 1, true))
    -- Naming the fault matters as much as naming the word. Reported through
    -- the generic unclaimed-list path this read "attribute list precedes no
    -- element it can apply to", which sends an author who typed {indx} to
    -- look at the placement of a line that is merely misspelled.
    assert.is_truthy(msg:find("unrecognized directive", 1, true))
  end)

  it("downgrades an unrecognized bare word under --lenient, preserving the line", function()
    local out = table.concat(blocks.transform(
      scanner.scan("{nonsense}\n"), lenient_cfg(), "f.md"), "\n")
    assert.is_truthy(out:find("{nonsense}", 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("does not transform a directive line inside a fenced code block", function()
    local out = run("```markua\n{index}\n```\n")
    assert.is_truthy(out:find("{index}", 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("recognizes {quiz-answers} without colliding with a future rejection of {quiz}", function()
    -- Exact-word lookup, not prefix: DIRECTIVES has no "quiz" entry, only
    -- "quiz-answers", so Task 8's eventual {quiz} rejection cannot be
    -- short-circuited by this table.
    local out = run("{quiz-answers}\n")
    assert.is_truthy(out:find('::: {.insert insert="quiz-answers"}', 1, true))
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/blocks_spec.lua`
Expected: FAIL with "module 'src.markua.blocks' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/blocks.lua`:

```lua
--- Block-level Markua to pandoc-markdown rewrites.
--
-- Handles the block-level constructs Markua layers on top of CommonMark: the
-- pending attribute-list lifecycle every construct below binds into, blurbs
-- and asides (each with a run-of-lines form and a fenced form), the eight
-- documented blurb sugar prefixes, and the closed set of bare-word matter and
-- insertion directives.
--
-- Blurbs (`B>` runs and `{blurb, class: X} ... {/blurb}`) and asides (`A>`
-- runs and `{aside} ... {/aside}`) share their consume-until-close loop and
-- class-resolution machinery, but differ in two ways. A bare blurb defaults
-- to callout class `information` (R4); a bare aside has no callout-class
-- default at all (R11) and stays a plain `::: {.aside}`. And a pending
-- attribute list ahead of an `A>` run is APPLIED, while one ahead of a fenced
-- `{aside}` opener is REJECTED -- mirroring the fenced `{blurb}` prohibition
-- (KTD7).
--
-- The eight documented sugar prefixes (C/D/E/I/Q/T/W/X>) share one dispatch
-- with `B>` itself, table-driven (KTD10) since Lua patterns have no
-- alternation. A pending attribute list's explicit class overrides a
-- prefix's implied one rather than conflicting with it, reported as a
-- warning rather than a hard error when the two disagree (KTD10a).
--
-- Bare-word directives (the `DIRECTIVES` table below) each lower to a
-- self-closing marker, ahead of the generic "unclaimed attribute list"
-- fallback this pass uses last -- a bare word outside that table, e.g.
-- "nonsense", falls through to that fallback and is rejected exactly as any
-- other unrecognized list is. `frontmatter` rides the `matter` family even
-- though the spec calls the directive nonexistent and asks a Processor to
-- ignore it (KTD5) -- emitting an inert marker *is* ignoring it while
-- preserving the author's intent for a downstream filter. `pagebreak` rides
-- `insert` alongside the front-/back-matter insertion directives rather than
-- getting a marker family of its own, since a third family with one member
-- buys nothing (KTD4).
local attributes = require("src.markua.attributes")
local config = require("src.markua.config")
local errors = require("src.markua.errors")

local M = {}

-- Strip a construct's line prefix and the one space Markua allows after it
-- ("B> text" and "B>text" both mean the same body). Shared by every prefixed
-- construct (B>, A>, and the eight sugar prefixes), so the one-space rule
-- lives in one place.
local function strip_prefix(text, prefix)
  local body = text:sub(#prefix + 1)
  return (body:gsub("^ ", ""))
end

-- Sugar prefix -> implied callout class (R5). `B` carries no implied class of
-- its own: it is the general blurb form, falling back to a pending list's
-- class or, absent one, R4's `information` default. Every other prefix names
-- the class Markua 0.30 documents for it. Table-driven rather than a branch
-- chain (KTD10) -- Lua patterns have no alternation, and scanner.lua and
-- config.lua both already hold their own alternatives as data, not a chain of
-- `elseif`s.
local BLURB_PREFIXES = {
  { prefix = "B>", class = nil },
  { prefix = "C>", class = "center" },
  { prefix = "D>", class = "discussion" },
  { prefix = "E>", class = "error" },
  { prefix = "I>", class = "information" },
  { prefix = "Q>", class = "question" },
  { prefix = "T>", class = "tip" },
  { prefix = "W>", class = "warning" },
  { prefix = "X>", class = "exercise" },
}

-- Which entry (if any) opens `text` as a blurb run. A loop over the table
-- above, for the same reason the table exists: Lua's patterns cannot
-- alternate, so this cannot collapse into one combined pattern.
local function find_blurb_prefix(text)
  for _, entry in ipairs(BLURB_PREFIXES) do
    if text:sub(1, #entry.prefix) == entry.prefix then
      return entry
    end
  end
  return nil
end

-- Enrich an unknown-class error with the registered spelling when the two
-- differ only by letter case (KTD8). Matching itself stays case-sensitive --
-- this never changes which class resolves, only what an author sees when
-- they typed the wrong case.
local function known_spelling(name, cfg)
  local lower = name:lower()
  for _, c in ipairs(cfg.callout_classes) do
    if c ~= name and c:lower() == lower then
      return c
    end
  end
  return nil
end

-- Scan a class list for the one registered callout class. Per KTD10b, a
-- Markua attribute list is key-value only -- every class, callout or
-- decorative, arrives through one `class:` value that attributes.parse
-- splits on whitespace -- so there is no shorthand to distinguish intent by,
-- and a membership scan is the whole rule. Returns the callout class plus
-- every other class in source order (R8, the decorative-class case); reports
-- when none of the classes is registered (R6).
--
-- Reporting rather than raising is deliberate. AGENTS.md makes an unknown
-- construct a hard error that `--lenient` downgrades to a warning, and an
-- unregistered class is exactly that; the reference this pass started from
-- used an unconditional raise, which left `--lenient` able to recover from an
-- unclaimed attribute list but not from a bad class. That asymmetry defeats
-- leniency for its documented job -- triaging a manuscript whose classes do
-- not match this book's list, which is the common case, since real Leanpub
-- builds reject `note` and books narrow the set further. Under leniency the
-- author's own first class becomes the head, so their text survives into the
-- output the same way reject_pending preserves an unclaimed list.
local function resolve_callout_class(classes, cfg, file, line)
  for idx, c in ipairs(classes) do
    if config.is_callout_class(cfg, c) then
      local decoratives = {}
      for j, other in ipairs(classes) do
        if j ~= idx then
          decoratives[#decoratives + 1] = other
        end
      end
      return c, decoratives
    end
  end
  local hint = ""
  for _, c in ipairs(classes) do
    local known = known_spelling(c, cfg)
    if known then
      hint = " (classes are case-sensitive; did you mean '" .. known .. "'?)"
      break
    end
  end
  errors.report(cfg, file, line,
    "unknown callout class '" .. table.concat(classes, "', '") .. "'" .. hint)
  local head = classes[1]
  local decoratives = {}
  for j = 2, #classes do
    decoratives[#decoratives + 1] = classes[j]
  end
  return head, decoratives
end

-- A B> run or fenced opener with no explicit class defaults to `information`
-- (R4); an empty class list never reaches resolve_callout_class, so the
-- default never has an unresolvable line/file to report against.
local function callout_classes(classes, cfg, file, line)
  if #classes == 0 then
    return "information", {}
  end
  return resolve_callout_class(classes, cfg, file, line)
end

-- Bare-word directive -> which self-closing marker family it emits (R14,
-- R15). One table, not two, so the whole recognized set is enumerable in one
-- place -- that is what makes R19's hard error trustworthy: a caller can see
-- every legal bare word by reading this table rather than reconciling two.
--
-- `frontmatter` is listed under "matter" even though spec.txt:2288 says the
-- directive "does not exist" and a Processor "should ignore it if it is
-- encountered": real manuscripts write it anyway, and the spec's own remedy
-- is to ignore rather than reject. Emitting an inert marker *is* ignoring it
-- while preserving the author's intent for a downstream filter (KTD5).
--
-- `pagebreak` is listed under "insert" rather than getting a marker family of
-- its own: spec.txt:2219 groups it with neither the structural pair nor the
-- two closed insertion lists, but it inserts something at a point, which is
-- what `.insert` already means, and a third family with one member buys
-- nothing (KTD4).
local DIRECTIVES = {
  mainmatter = "matter",
  backmatter = "matter",
  frontmatter = "matter",
  pagebreak = "insert",
  ["half-title"] = "insert",
  ["series-title"] = "insert",
  ["title-page"] = "insert",
  copyright = "insert",
  dedication = "insert",
  epigraph = "insert",
  toc = "insert",
  figures = "insert",
  tables = "insert",
  index = "insert",
  ["exercise-answers"] = "insert",
  ["quiz-answers"] = "insert",
}

-- An attribute list holding only index keys belongs to inline.transform,
-- which runs after this pass. Re-emit it untouched rather than treating it
-- as a pending block attribute, or a standalone {ix: "term"} line would
-- surface as literal text in the finished book.
local function is_index_only(parsed, cfg)
  if parsed.id or #parsed.classes > 0 or #parsed.bare > 0 then
    return false
  end
  local count = 0
  for key in pairs(parsed.keyvals) do
    if not config.is_index_key(cfg, key) then
      return false
    end
    count = count + 1
  end
  return count > 0
end

function M.transform(lines, cfg, file)
  local out = {}
  local pending = nil        -- attribute list awaiting its element
  local pending_text = nil   -- the raw line, for verbatim re-emission
  local i = 1

  local function emit(s)
    out[#out + 1] = s
  end

  -- A body line that is exactly ":::" or "$$" would close a fence this pass
  -- opened elsewhere in the document, desynchronizing every block after it.
  -- pandoc's own markdown writer backslash-escapes such a line rather than
  -- erroring (a ":::" paragraph inside a div is written "\:::" and reads
  -- back identically), so every non-fence, non-attribute line this pass
  -- emits goes through here -- not only the blurb and aside bodies this
  -- module builds, because a plain paragraph elsewhere in the document can
  -- collide with a delimiter this pass generates just as easily.
  local function emit_body(s)
    if s:match("^%s*:::+%s*$") or s:match("^%s*%$%$%s*$") then
      emit((s:gsub("^(%s*)", "%1\\", 1)))
    else
      emit(s)
    end
  end

  -- The callout class MUST be the head of the class list, and `.blurb` /
  -- `.aside` MUST be last: pandoc's DocBook writer matches only the first
  -- class (`(l:_) | l `elem` admonitions`), so "{.blurb .tip}" degrades to a
  -- bare <para> with no error anywhere, while "{.tip .blurb}" becomes a real
  -- <tip>. Decorative classes ride between the two, in the source order the
  -- author wrote them (R8) -- the reference this pass started from resolved
  -- one callout class and silently dropped every other one, which this
  -- fixes by taking the whole list instead of a single resolved name.
  --
  -- `id`, when given, leads the attribute block as `#id` -- the shape
  -- `attributes.to_pandoc_attr` already uses, and one the pandoc oracle
  -- confirms sets the Div's identifier identically to a Markua `id:` key
  -- rendered as `id="..."`. The sugar-prefix branch below is the only caller
  -- that passes one, carrying a pending list's id onto a sugar-prefix blurb
  -- (R5a) rather than dropping it.
  --
  -- `head` and every entry of `decoratives`, plus `id` when given, are
  -- validated through attributes.check_name before anything is emitted --
  -- the same check attributes.to_pandoc_attr already applies to every id and
  -- class it renders. This path builds its own `::: {...}` text directly
  -- rather than going through to_pandoc_attr, so it must call that
  -- validation itself: without it, an author's `{class: "tip 3bad"}` reaches
  -- pandoc.read as `::: {.tip .3bad .blurb}`, and pandoc rejects the WHOLE
  -- attribute block on the illegal class, destroying the blurb and leaking
  -- literal braces into the finished book -- exactly the failure AGENTS.md's
  -- "never pass through as literal braces" rule forbids. check_name raises
  -- unconditionally rather than going through errors.report, matching its
  -- own behavior inside to_pandoc_attr: an id or class pandoc's attribute
  -- syntax cannot represent is a "cannot be rendered" fault, not an
  -- "unrecognized Markua construct" one that --lenient is meant to downgrade.
  --
  -- `marker` is never validated: it is always one of this module's own
  -- literals ("blurb" / "aside"), never author input.
  local function open_div(head, decoratives, marker, id, line)
    if id then
      attributes.check_name("id", id, file, line)
    end
    attributes.check_name("class", head, file, line)
    for _, c in ipairs(decoratives) do
      attributes.check_name("class", c, file, line)
    end
    local parts = {}
    if id then
      parts[#parts + 1] = "#" .. id
    end
    parts[#parts + 1] = "." .. head
    for _, c in ipairs(decoratives) do
      parts[#parts + 1] = "." .. c
    end
    parts[#parts + 1] = "." .. marker
    emit("::: {" .. table.concat(parts, " ") .. "}")
  end

  -- Unlike a blurb, a bare aside has no callout-class default: `A>` alone
  -- and an empty `{aside}` both emit exactly `::: {.aside}` (R11, R12) --
  -- Task 11's downstream filter and issue #6's table expect that bare
  -- shape, so there is no `information` fallback to reach for here the way
  -- callout_classes gives blurbs. A non-empty class list resolves through
  -- the same resolve_callout_class a blurb's does, so a bad class raises
  -- identically in both constructs (KTD7).
  local function open_aside(classes, line)
    if not classes or #classes == 0 then
      emit("::: {.aside}")
    else
      local head, decoratives = resolve_callout_class(classes, cfg, file, line)
      open_div(head, decoratives, "aside", nil, line)
    end
  end

  -- Consume lines up to (not including) the fenced closer for `marker`,
  -- shared by the {blurb} and {aside} fenced forms (R3, R12): a code sample
  -- inside the body can legitimately contain the closing text, so only a
  -- matching line OUTSIDE a fence terminates the construct (R10), and the
  -- closer word is taken from `marker` rather than hardcoded so this one
  -- loop can never let a {blurb} div wait on {/aside} or vice versa.
  local function consume_until_close(marker, opened_at)
    local closer = "^%s*{/" .. marker .. "}%s*$"
    i = i + 1
    while i <= #lines and not (not lines[i].in_code and lines[i].text:match(closer)) do
      emit_body(lines[i].text)
      i = i + 1
    end
    if i > #lines then
      -- R9/R12: a block running silently to end of input is exactly what
      -- this guards against. Position the error at the opener, not here,
      -- since "here" is past the last line an author can point to.
      errors.raise(file, opened_at, "unclosed {" .. marker .. "} opened here")
    end
    emit(":::")
    i = i + 1
  end

  -- Consume every consecutive line sharing `prefix`, emitting each one's body
  -- through emit_body, then close with ":::". Shared by the A> branch and the
  -- blurb-prefix branch below -- both open their div first, then hand off
  -- here to swallow their own run and close it. "A>" is a fixed literal, so
  -- `text:match("^A>")` (the run's opening condition) and the `sub`-based
  -- comparison this loop uses are equivalent for it; using `sub` uniformly
  -- means one implementation serves every prefix, fixed or table-driven
  -- alike. Advances `i` on its own, past every line it consumes, exactly
  -- like consume_until_close above.
  local function consume_prefixed_run(prefix)
    while i <= #lines and lines[i].text:sub(1, #prefix) == prefix do
      emit_body(strip_prefix(lines[i].text, prefix))
      i = i + 1
    end
    emit(":::")
  end

  -- Nothing may see a pending attribute list and quietly forget it. Every
  -- exit from the pending state goes through here, so an unclaimed list
  -- aborts with its own line number instead of leaking braces into the book
  -- or vanishing (R21). Called as the FIRST action of any branch that does
  -- not consume the pending list itself -- the branches that do consume it
  -- (the heading attach, and the B>, A>, and sugar-prefix branches) are
  -- untouched by this rule.
  local function reject_pending(reason)
    if not pending then
      return
    end
    local text = pending_text
    errors.report(cfg, file, pending.line,
      (reason or "attribute list applies to nothing") .. ": " .. text)
    -- Only reached when cfg.strict is false. Re-emit verbatim, at the
    -- position of the line that disqualified it: leniency preserves the
    -- author's text and never reorders or deletes it (R22). Resolving this
    -- in the same loop iteration as the disqualifying line -- rather than
    -- tracking and rewriting an output index -- is what keeps that true
    -- without bookkeeping: the append lands here, before whatever that line
    -- goes on to emit.
    emit(text)
    pending, pending_text = nil, nil
  end

  while i <= #lines do
    local rec = lines[i]
    local text = rec.text
    local blurb_prefix = find_blurb_prefix(text)

    if rec.in_code then
      emit(text)
      i = i + 1

    elseif attributes.is_attribute_line(text) then
      local parsed = attributes.parse(text, file, rec.number)

      if is_index_only(parsed, cfg) then
        reject_pending()
        emit(text)                     -- verbatim; inline.transform owns it
        i = i + 1
      elseif #parsed.bare == 1 and parsed.bare[1] == "blurb" then
        -- Fenced form: {blurb, class: X} ... {/blurb}. A pending list on the
        -- line above this opener is illegal per R13a (spec.txt:6647-6656),
        -- so it is rejected first, before anything of this branch's own is
        -- emitted -- exactly the rule reject_pending's own comment describes
        -- for every branch that does not consume the pending list.
        reject_pending("attribute list may not precede a fenced {blurb} opener")
        local head, decoratives = callout_classes(parsed.classes, cfg, file, rec.number)
        open_div(head, decoratives, "blurb", nil, rec.number)
        consume_until_close("blurb", rec.number)
      elseif #parsed.bare == 1 and parsed.bare[1] == "aside" then
        -- Fenced form: {aside, class: X} ... {/aside}. Sibling of the {blurb}
        -- branch above -- a preceding list is illegal here too (R13a,
        -- KTD7), rejected before this branch emits anything of its own --
        -- but open_aside (unlike callout_classes) has no default class to
        -- fall back to when parsed.classes is empty (R12).
        reject_pending("attribute list may not precede a fenced {aside} opener")
        open_aside(parsed.classes, rec.number)
        consume_until_close("aside", rec.number)
      elseif #parsed.bare == 1 and DIRECTIVES[parsed.bare[1]] then
        -- Bare-word directive. A pending list does not bind to a directive
        -- line -- mirroring the fenced {blurb}/{aside} prohibition (R13a) --
        -- so it is rejected first, exactly like every other branch that does
        -- not consume the pending list itself; a leftover {class: X} above
        -- {pagebreak} raises instead of silently vanishing.
        reject_pending("attribute list does not precede a directive")
        local word = parsed.bare[1]
        local kind = DIRECTIVES[word]
        -- The class and the attribute key are both the kind; the value is
        -- the bare word verbatim, so no name is translated anywhere (R18).
        -- Self-closing, not a wrapper (R16, R17): confirmed against the
        -- reader's own TARGET_FORMAT that prose following the marker is a
        -- SIBLING Para, not nested inside an empty Div (KTD3).
        emit(string.format('::: {.%s %s="%s"}', kind, kind, word))
        emit(":::")
        i = i + 1
      elseif #parsed.bare == 1 then
        -- A lone bare word that reached here is not `blurb`, not `aside`,
        -- and not in DIRECTIVES, so it is an unrecognized directive and
        -- nothing downstream will claim it (R19). Say that, rather than
        -- letting it fall through to the generic swap below: that path
        -- reports "attribute list precedes no element it can apply to",
        -- which misdescribes a typo like {indx} as a placement problem and
        -- sends the author looking at the wrong line. Naming the word and
        -- the real fault is the entire value of the hard error -- a
        -- misdiagnosing abort is barely better than the silent
        -- pass-through AGENTS.md forbids. Reported, not raised, so
        -- `--lenient` still downgrades it like every other unknown
        -- construct.
        reject_pending()
        errors.report(cfg, file, rec.number,
          "unrecognized directive '" .. parsed.bare[1] .. "'")
        emit(text)                     -- lenient only; preserve the author's line
        i = i + 1
      else
        -- Every other attribute list falls through to this generic swap,
        -- which is what keeps it from silently binding to whatever line
        -- happens to follow it (R21).
        reject_pending()               -- a new list may not shadow an unused one
        pending, pending_text = parsed, text
        i = i + 1
      end

    elseif text:match("^A>") then
      -- A> run: unlike a fenced {aside} opener, a pending list here is
      -- APPLIED rather than rejected (KTD7) -- open_aside resolves it
      -- exactly as the fenced form does, falling back to the bare
      -- `::: {.aside}` shape when no list precedes the run at all (R11).
      if pending then
        open_aside(pending.classes, pending.line)
        pending, pending_text = nil, nil
      else
        open_aside({}, rec.number)
      end
      consume_prefixed_run("A>")

    elseif blurb_prefix then
      -- B> run and the eight sugar prefixes share one path (KTD10): they
      -- differ only in what class an EMPTY pending list resolves to. A
      -- pending list carrying its own class always wins over the prefix's
      -- implied one (KTD10a, R5a) -- the spec's own worked example renders
      -- {class: tip} above W> as a tip blurb, not a failed conversion -- so
      -- disagreement between the two is a warning, not a hard error, fired
      -- only when they actually differ. consume_prefixed_run swallows every
      -- consecutive line sharing the SAME prefix and closes the div, so --
      -- unlike the branches below -- it advances `i` on its own and sits
      -- outside their shared trailing increment.
      local pending_classes = pending and pending.classes or {}
      -- Markua's own id syntax is the `id:` key (KTD10b), which
      -- attributes.parse lands in .keyvals.id; `.id` itself is only ever set
      -- by the `#id` shorthand pandoc uses and Markua does not. Checking
      -- both costs nothing and means an id reaches the div regardless of
      -- which shape produced it.
      local id = pending and (pending.id or pending.keyvals.id) or nil
      local head, decoratives, applied_line
      if #pending_classes > 0 then
        applied_line = pending.line
        head, decoratives = callout_classes(pending_classes, cfg, file, applied_line)
        if blurb_prefix.class and head ~= blurb_prefix.class then
          errors.warn(file, applied_line, string.format(
            "explicit class '%s' overrides %s's implied class '%s'", head, blurb_prefix.prefix, blurb_prefix.class),
            cfg.sink)
        end
      elseif blurb_prefix.class then
        applied_line = rec.number
        head, decoratives = blurb_prefix.class, {}
      else
        applied_line = rec.number
        head, decoratives = callout_classes({}, cfg, file, applied_line)
      end
      pending, pending_text = nil, nil
      open_div(head, decoratives, "blurb", id, applied_line)
      consume_prefixed_run(blurb_prefix.prefix)

    else
      if pending and text:match("^#+%s") then
        -- to_pandoc_attr renders id, classes and keyvals only. An
        -- unrecognized bare word would vanish into an empty "{}" on the
        -- heading, which is exactly the silent pass-through the hard-error
        -- constraint forbids.
        if #pending.bare > 0 then
          reject_pending("unrecognized attribute `" .. pending.bare[1] .. "`")
          emit(text)
        else
          -- No explicit line: to_pandoc_attr falls back to parsed.line,
          -- which is the same position pending.line already carries.
          emit(text .. " " .. attributes.to_pandoc_attr(pending, file))
          pending, pending_text = nil, nil
        end
      else
        -- Covers plain prose and blank lines; A> lines are handled by their
        -- own branch above, not here. A blank line no longer holds a
        -- pending list across it (KTD6): spec.txt:6647 requires the
        -- attribute list to directly precede its element with no blank line
        -- between them, so a blank goes through the same rejection as any
        -- other unclaimed case, not a special case that survives it.
        reject_pending("attribute list precedes no element it can apply to")
        emit_body(text)
      end
      i = i + 1
    end
  end

  -- A list in the final position still applies to nothing. This is live, not
  -- a safety net: scanner.scan appends a trailing blank record only when the
  -- source ends in a newline, so a file whose last line is the attribute list
  -- and carries no final newline reaches here with `pending` still set. That
  -- is the one path satisfying R21's "end of input" case, and deleting it as
  -- unreachable would silently drop the error.
  reject_pending("attribute list at end of input")

  return out
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/blocks_spec.lua`
Expected: PASS, 71 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/blocks.lua test/blocks_spec.lua
git commit -m "feat: blurbs, asides, matter directives, part headings"
```

---

## Phase 3: Inline constructs

### Task 6: Index entries, superscript, subscript, inline math

**Files:**

- Create: `src/markua/inline.lua`
- Test: `test/inline_spec.lua`

**Interfaces:**

- Consumes: `config`
- Produces: `inline.transform(text, cfg) -> string`. Rewrites index markers to bracketed spans with class `indexref` and attribute `entry` (pandoc's own convention for a Word index field), `^x^` to pandoc superscript, `~x~` to subscript, and backtick-dollar inline math to `$...$`. Operates on a single line of prose and is only ever called on lines where `in_code` is false.

- [ ] **Step 1: Write the failing test**

Create `test/inline_spec.lua`:

```lua
local config = require("src.markua.config")
local inline = require("src.markua.inline")

local cfg = config.defaults()

describe("inline.transform", function()
  it("converts spec-form index markers to bracketed spans", function()
    local out = inline.transform('The {ix: "B-tree"} B-tree is fast.', cfg)
    assert.equals('The []{.indexref entry="B-tree"} B-tree is fast.', out)
  end)

  it("also accepts the {i:} variant", function()
    local out = inline.transform('A **token**{i: "token"} here.', cfg)
    assert.equals('A **token**[]{.indexref entry="token"} here.', out)
  end)

  it("preserves index hierarchy", function()
    local out = inline.transform('{ix: "Trees!B-tree"}x', cfg)
    assert.equals('[]{.indexref entry="Trees!B-tree"}x', out)
  end)

  it("converts inline math", function()
    local out = inline.transform("The value is `a^2 + b`$ here.", cfg)
    assert.equals("The value is $a^2 + b$ here.", out)
  end)

  it("converts superscript and subscript", function()
    assert.equals("E = mc^2^", inline.transform("E = mc^2^", cfg))
    assert.equals("H~2~O", inline.transform("H~2~O", cfg))
  end)

  it("leaves ordinary prose untouched", function()
    local s = "Nothing special here at all."
    assert.equals(s, inline.transform(s, cfg))
  end)

  it("does not double a percent sign in an index term", function()
    -- gsub only reprocesses % when the replacement is a string; these use a
    -- function, so escaping the replacement would corrupt rather than protect.
    local out = inline.transform('The {ix: "100% coverage"} matters.', cfg)
    assert.equals('The []{.indexref entry="100% coverage"} matters.', out)
  end)

  it("does not double a percent sign in inline math", function()
    assert.equals("Value $a % b$ here.", inline.transform("Value `a % b`$ here.", cfg))
  end)

  it("tolerates a space before the colon", function()
    -- attributes.lua accepts "{ix : ...}", so this pass must not disagree.
    local out = inline.transform('A {ix : "term"} here.', cfg)
    assert.equals('A []{.indexref entry="term"} here.', out)
  end)

  it("converts two index markers on one line", function()
    local out = inline.transform('{ix: "a"} and {ix: "b"}', cfg)
    assert.equals('[]{.indexref entry="a"} and []{.indexref entry="b"}', out)
  end)

  it("leaves a Markua marker inside a code span alone", function()
    -- A book about Markua documents its own syntax. Rewriting inside backticks
    -- turns the example into a real index entry and the sentence stops
    -- teaching anything. scanner.lua makes fenced blocks opaque but cannot see
    -- inside a line, so the guard has to live here.
    local out = inline.transform('Write `{ix: "term"}` to index a term.', cfg)
    assert.equals('Write `{ix: "term"}` to index a term.', out)
  end)

  it("still converts a marker outside a code span on the same line", function()
    local out = inline.transform('`{ix: "shown"}` indexes {ix: "real"}.', cfg)
    assert.equals('`{ix: "shown"}` indexes []{.indexref entry="real"}.', out)
  end)
end)
```

Superscript and subscript already match pandoc's own syntax, so those two cases assert that the transform does not corrupt them.

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/inline_spec.lua`
Expected: FAIL with "module 'src.markua.inline' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/inline.lua`:

```lua
--- Inline Markua rewrites. Called only on non-code lines.
local M = {}

-- NOTE: no %-escaping helper here, deliberately. Lua reprocesses % in a gsub
-- replacement only when the replacement is a string. Every gsub below passes a
-- function, whose return value is used verbatim, so escaping would not be
-- undone -- it would just double every literal % in the output, turning
-- {ix: "100% coverage"} into entry="100%% coverage".

-- Apply `fn` only to the text between backtick code spans.
--
-- A code span is opaque. scanner.lua makes fenced blocks opaque, but it cannot
-- see inside a line, and a book *about* Markua is full of prose like
-- "write `{ix: \"term\"}` to index a term". Rewriting there turns the example
-- into a real index entry and the sentence stops teaching anything.
--
-- The %1 back-reference matches a closing run of the same length as the
-- opening run, so ``a `b` c`` behaves.
local function outside_code_spans(text, fn)
  local out, pos = {}, 1
  while true do
    local s, e = text:find("(`+).-%1", pos)
    if not s then
      out[#out + 1] = fn(text:sub(pos))
      return table.concat(out)
    end
    out[#out + 1] = fn(text:sub(pos, s - 1))
    out[#out + 1] = text:sub(s, e)   -- verbatim
    pos = e + 1
  end
end

function M.transform(text, cfg)
  -- Inline math runs first. `expr`$ is Markua math rather than a code span, so
  -- it has to be converted before the guard below makes backticks opaque --
  -- otherwise the guard would protect it from its own rewrite.
  text = text:gsub("`([^`]-)`%$", function(expr)
    return "$" .. expr .. "$"
  end)

  -- Index markers: {ix: "term"} and the {i: "term"} variant.
  -- Lua has no alternation, so loop over the configured keys. %s* after the
  -- key mirrors attributes.lua, which tolerates "{ix : ...}".
  return outside_code_spans(text, function(chunk)
    for _, key in ipairs(cfg.index_keys) do
      local pattern = "{" .. key .. '%s*:%s*"([^"]*)"%s*}'
      chunk = chunk:gsub(pattern, function(term)
        return '[]{.indexref entry="' .. term .. '"}'
      end)
    end
    return chunk
  end)
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/inline_spec.lua`
Expected: PASS, 12 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/inline.lua test/inline_spec.lua
git commit -m "feat: index markers and inline math"
```

---

## Phase 4: Resources

### Task 7: Resource dispatch by extension

**Files:**

- Create: `src/markua/resources.lua`
- Test: `test/resources_spec.lua`

**Interfaces:**

- Consumes: `attributes`
- Produces:
  - `resources.kind(path) -> "image"|"video"|"audio"|"code"|"table"|"math"|"unknown"` from the file extension.
  - `resources.transform(lines, file) -> array of strings`, rewriting `![alt](path "title")` preceded by an attribute list into a pandoc image with attributes, and converting code/CSV/math resources into the appropriate pandoc construct.

- [ ] **Step 1: Write the failing test**

Create `test/resources_spec.lua`:

```lua
local scanner = require("src.markua.scanner")
local resources = require("src.markua.resources")

local function run(text)
  return table.concat(resources.transform(scanner.scan(text), "f.md"), "\n")
end

describe("resources.kind", function()
  it("classifies by extension", function()
    assert.equals("image", resources.kind("images/a.png"))
    assert.equals("video", resources.kind("v/demo.mp4"))
    assert.equals("audio", resources.kind("a/intro.mp3"))
    assert.equals("code", resources.kind("code/cli.rb"))
    assert.equals("table", resources.kind("data/q4.csv"))
    assert.equals("math", resources.kind("math/euler.tex"))
  end)
end)

describe("resources.transform", function()
  it("attaches image sizing attributes to the image", function()
    local out = run('{height: "80%"}\n![A diagram](d.png "Caption")\n')
    assert.is_truthy(out:find('![A diagram](d.png "Caption"){height="80%"}', 1, true))
  end)

  it("turns a code resource into an include directive span", function()
    local out = run('{title: "The CLI", line-numbers: true}\n![](code/cli.rb)\n')
    assert.is_truthy(out:find('.code-resource', 1, true))
    assert.is_truthy(out:find('src="code/cli.rb"', 1, true))
    assert.is_truthy(out:find('title="The CLI"', 1, true))
  end)

  it("carries crop attributes through", function()
    local out = run('{crop-start: 10, crop-end: 42}\n![](code/cli.rb)\n')
    assert.is_truthy(out:find('crop-start="10"', 1, true))
  end)

  it("normalises legacy crop spellings to the spec names", function()
    local out = run('{leanpub-start-line: 3}\n![](code/cli.rb)\n')
    assert.is_truthy(out:find('crop-start="3"', 1, true))
    local suffixed = run('{crop-start-line: 7}\n![](code/cli.rb)\n')
    assert.is_truthy(suffixed:find('crop-start="7"', 1, true))
  end)

  it("leaves plain images alone", function()
    local out = run("![Alt](a.png)\n")
    assert.is_truthy(out:find("![Alt](a.png)", 1, true))
  end)

  it("does not emit a video as a pandoc image", function()
    -- An Image node for an .mp4 becomes a broken <img> in EPUB and HTML.
    local out = run("![A demo](v/demo.mp4)\n")
    assert.is_truthy(out:find(".video-resource", 1, true))
    assert.is_nil(out:find("![A demo](v/demo.mp4)", 1, true))
  end)

  it("dispatches audio to its own resource span", function()
    local out = run("![Intro](a/intro.mp3)\n")
    assert.is_truthy(out:find(".audio-resource", 1, true))
  end)

  it("never rewrites a resource line inside a code fence", function()
    local out = run("```markua\n{height: \"80%\"}\n![x](d.png)\n```\n")
    assert.is_truthy(out:find('{height: "80%"}', 1, true))
    assert.is_nil(out:find("height=", 1, true))
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/resources_spec.lua`
Expected: FAIL with "module 'src.markua.resources' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/resources.lua`:

```lua
--- Markua resources: one syntax, many media, dispatched by extension.
--
-- Only images survive as pandoc Images. Everything else -- code, tables, math,
-- video, audio -- becomes an annotated span for a later filter to lower into
-- whatever the target format supports, because pandoc has no native node for
-- them. Emitting a video as an Image would produce a broken <img> in EPUB.
local attributes = require("src.markua.attributes")

local M = {}

local KIND_BY_EXT = {
  png = "image", jpg = "image", jpeg = "image", gif = "image", svg = "image",
  mp4 = "video", webm = "video", mov = "video", m4v = "video",
  avi = "video", mkv = "video", ogv = "video",
  mp3 = "audio", m4a = "audio", wav = "audio", ogg = "audio",
  flac = "audio", aac = "audio",
  csv = "table",
  tex = "math",
}

-- Attribute lists that blocks.transform owns, not this pass. Two shapes:
-- an index-only list ({ix: "term"} / {i: "term"}), and a list whose bare word
-- is a block keyword ({blurb, class: tip}, {frontmatter}). Claiming either as
-- resource attributes is silent data loss -- the index entry disappears into
-- the image's attribute string, and a fenced blurb whose first body line is a
-- resource loses its opening marker and leaves {/blurb} unpaired.
--
-- MUST stay in sync with blocks.lua's own DIRECTIVES table (plus "blurb" and
-- "aside", the two fenced-form openers, and "quiz"/"exercise", which blocks.lua
-- rejects rather than lowers): resources.transform runs BEFORE
-- blocks.transform, and belongs_to_blocks returns false for any bare word
-- outside this table. A directive or a fenced-aside opener sitting directly
-- above an image line would then be claimed as that image's attributes and
-- vanish silently -- the same failure mode the comment above already
-- describes for {blurb} and {frontmatter}, just for every word this table
-- omits.
local BLOCK_BARE = {
  blurb = true, aside = true,
  frontmatter = true, mainmatter = true, backmatter = true,
  quiz = true, exercise = true,
  pagebreak = true,
  ["half-title"] = true, ["series-title"] = true, ["title-page"] = true,
  copyright = true, dedication = true, epigraph = true,
  toc = true, figures = true, tables = true, index = true,
  ["exercise-answers"] = true, ["quiz-answers"] = true,
}

local function belongs_to_blocks(parsed)
  for _, word in ipairs(parsed.bare) do
    if BLOCK_BARE[word] then
      return true
    end
  end
  if parsed.id or #parsed.classes > 0 or #parsed.bare > 0 then
    return false
  end
  local saw_key = false
  for k in pairs(parsed.keyvals) do
    if k ~= "ix" and k ~= "i" then
      return false
    end
    saw_key = true
  end
  return saw_key
end

-- The Markua spec names these `crop-start` and `crop-end`. The `-line` suffixed
-- spellings and the `leanpub-` ones are real-world variants that appear in
-- manuscripts; normalize every spelling to the spec name so exactly one key
-- reaches the filter.
local LEGACY_ALIAS = {
  ["leanpub-start-line"] = "crop-start",
  ["leanpub-end-line"] = "crop-end",
  ["crop-start-line"] = "crop-start",
  ["crop-end-line"] = "crop-end",
}

function M.kind(path)
  local ext = path:match("%.([%w]+)$")
  if not ext then
    return "unknown"
  end
  ext = ext:lower()
  if KIND_BY_EXT[ext] then
    return KIND_BY_EXT[ext]
  end
  -- Anything else with an extension is treated as an embeddable code file.
  return "code"
end

local function normalise(parsed)
  for legacy, canonical in pairs(LEGACY_ALIAS) do
    if parsed.keyvals[legacy] then
      parsed.keyvals[canonical] = parsed.keyvals[legacy]
      parsed.keyvals[legacy] = nil
    end
  end
  return parsed
end

function M.transform(lines, file)
  local out = {}
  local pending, pending_line = nil, nil

  -- Re-emitting a non-resource attribute line must reproduce it VERBATIM.
  -- to_pandoc_attr drops `bare` words, so rendering through it would turn
  -- {blurb, class: warning} into {.warning} and {frontmatter} into {}, and
  -- blocks.transform (which runs after this pass) could never see them.
  local pending_text = nil

  local function flush_pending()
    if pending_text then
      out[#out + 1] = pending_text
      pending, pending_text = nil, nil
    end
  end

  for i = 1, #lines do
    local rec = lines[i]
    local text = rec.text

    if rec.in_code then
      out[#out + 1] = text
    elseif attributes.is_attribute_line(text) then
      flush_pending()
      pending = normalise(attributes.parse(text, file, rec.number))
      pending_text = text
      pending_line = rec.number
    else
      local alt, path, title = text:match('^!%[(.-)%]%(([^%s)]+)%s*(.-)%)%s*$')
      if path then
        -- Give the line back to blocks.transform before claiming anything.
        if pending and belongs_to_blocks(pending) then
          flush_pending()
        end
        local kind = M.kind(path)
        if kind == "code" or kind == "table" or kind == "math"
           or kind == "video" or kind == "audio" then
          local parsed = pending or { id = nil, classes = {}, keyvals = {}, bare = {} }
          parsed.classes[#parsed.classes + 1] = kind .. "-resource"
          parsed.keyvals["src"] = path
          out[#out + 1] = "[]" .. attributes.to_pandoc_attr(parsed)
        elseif pending then
          local suffix = attributes.to_pandoc_attr(pending)
          local titlepart = title ~= "" and (" " .. title) or ""
          out[#out + 1] = string.format("![%s](%s%s)%s", alt, path, titlepart, suffix)
        else
          out[#out + 1] = text
        end
        pending, pending_text = nil, nil
      else
        -- Flush before the current line even when it is blank. Holding a
        -- pending attribute line across a blank line re-emits it *after* the
        -- blank, which merges a standalone {ix: "term"} into the following
        -- paragraph instead of leaving it its own block.
        flush_pending()
        out[#out + 1] = text
      end
    end
  end

  -- An attribute line in the last position still belongs in the output.
  flush_pending()

  return out
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/resources_spec.lua`
Expected: PASS, 9 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/resources.lua test/resources_spec.lua
git commit -m "feat: resource dispatch by extension with crop aliases"
```

---

### Task 8: Display math fences and quiz rejection

**Files:**

- Modify: `src/markua/blocks.lua` (add math-fence and quiz handling to `M.transform`)
- Modify: `test/blocks_spec.lua`

**Interfaces:**

- Consumes: unchanged
- Produces: `blocks.transform` additionally converts a fence whose info string is `$` into `$$` delimiters, and raises a `MarkuaError` on a `{quiz...}` or `{exercise...}` attribute line.

- [ ] **Step 1: Write the failing test**

Append to `test/blocks_spec.lua`:

```lua
describe("blocks.transform math and quizzes", function()
  it("converts a ```$ fence into $$ display math", function()
    local out = run("```$\n\\frac{1}{2}\n```\n")
    assert.is_truthy(out:find("$$", 1, true))
    assert.is_nil(out:find("```", 1, true))
  end)

  it("rejects quizzes as out of scope", function()
    local ok, err = pcall(run, "{quiz, id: q1}\n# Quiz\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("quiz", 1, true))
  end)

  it("rejects exercises as out of scope", function()
    local ok, err = pcall(run, "{exercise, id: e1}\n# Ex\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("exercise", 1, true))
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/blocks_spec.lua`
Expected: FAIL, 3 new failures (math fence unchanged, quizzes not rejected)

- [ ] **Step 3: Implement the minimal code to make the test pass**

In `src/markua/blocks.lua`, add near the top after the `MATTER` table:

```lua
local OUT_OF_SCOPE = { quiz = true, exercise = true }
```

Inside `M.transform`, replace the `if rec.in_code then` branch with:

```lua
    if rec.in_code then
      if rec.fence == "open" and rec.info == "$" then
        emit("$$")
      elseif rec.fence == "close" and math_open then
        emit("$$")
      else
        emit(text)
      end
      if rec.fence == "open" and rec.info == "$" then
        math_open = true
      elseif rec.fence == "close" then
        math_open = false
      end
      i = i + 1
```

and declare `local math_open = false` alongside `local pending = nil`.

In the attribute-line branch, before the `MATTER` check, add:

```lua
      for _, word in ipairs(parsed.bare) do
        if OUT_OF_SCOPE[word] then
          errors.raise(file, rec.number,
            word .. " blocks are not supported by this reader (Markua 0.10 courses)")
        end
      end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/blocks_spec.lua`
Expected: PASS, 74 successes

- [ ] **Step 5: Commit**

```bash
git add src/markua/blocks.lua test/blocks_spec.lua
git commit -m "feat: display math fences; reject quizzes and exercises"
```

---

## Phase 5: Reader, filters, CLI

### Task 9: The Reader entry point

**Files:**

- Create: `src/markua.lua`
- Create: `test/golden.sh`
- Create: `test/golden/blurb-tip.md`, `test/golden/blurb-tip.native`
- Create: `test/golden/index-entries.md`, `test/golden/index-entries.native`

**Interfaces:**

- Consumes: `scanner`, `blocks`, `inline`, `resources`, `config`
- Produces: a global `Reader(inputs, opts)` returning a `pandoc.Pandoc`. This is the only file permitted to reference the `pandoc` global.

- [ ] **Step 1: Write the failing golden test**

Create `test/golden/blurb-tip.md`:

```markua
{class: tip}
B> Press `Ctrl-R` to search history.
```

Create `test/golden.sh`:

```bash
#!/usr/bin/env bash
# Golden-file tests. Each test/golden/<name>.md is read with the custom
# reader and compared against <name>.native. Regenerate with UPDATE=1.
set -uo pipefail

fail=0
for md in test/golden/*.md; do
    expected="${md%.md}.native"
    # Check the exit status before anything else. Without this, UPDATE=1 would
    # happily write a crash's stderr into the .native file, and every later run
    # would diff that stack trace against itself and report ok.
    if ! actual=$(pandoc --from=src/markua.lua --to=native "$md" 2>&1); then
        echo "FAIL $md (pandoc exited non-zero)"
        printf '%s\n' "$actual" | sed 's/^/    /'
        fail=1
        continue
    fi
    if [ "${UPDATE:-0}" = "1" ]; then
        printf '%s\n' "$actual" > "$expected"
        echo "updated $expected"
        continue
    fi
    if [ ! -f "$expected" ]; then
        echo "MISSING $expected"; fail=1; continue
    fi
    if ! diff -u "$expected" <(printf '%s\n' "$actual") > /tmp/golden.diff; then
        echo "FAIL $md"; cat /tmp/golden.diff; fail=1
    else
        echo "ok   $md"
    fi
done
exit $fail
```

```bash
chmod +x test/golden.sh
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./test/golden.sh`
Expected: FAIL — pandoc cannot load `src/markua.lua` (file does not exist)

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua.lua`:

```lua
--- Markua custom reader for pandoc.
--
-- Delegating design: rewrite Markua-only syntax into pandoc-flavored
-- markdown, then let pandoc's own parser do the CommonMark-shaped work.
-- A native parser would mean reimplementing CommonMark in Lua.
--
-- This is the ONLY module allowed to touch the `pandoc` global. Everything
-- under src/markua/ is pure Lua so it can be unit-tested with busted, which
-- runs under system Lua and has no pandoc module.

package.path = table.concat({
  (PANDOC_SCRIPT_FILE or ""):gsub("[^/]*$", "") .. "../?.lua",
  package.path,
}, ";")

local scanner = require("src.markua.scanner")
local blocks = require("src.markua.blocks")
local inline = require("src.markua.inline")
local resources = require("src.markua.resources")
local config = require("src.markua.config")

local TARGET_FORMAT = table.concat({
  "markdown_strict",
  "fenced_divs", "bracketed_spans", "header_attributes",
  "pipe_tables", "footnotes", "definition_lists",
  "strikeout", "superscript", "subscript",
  "tex_math_dollars", "backtick_code_blocks", "fenced_code_blocks", "fenced_code_attributes",
  "link_attributes", "smart",
}, "+")

--- Run the pure-Lua pipeline over a document.
local function preprocess(text, cfg, file)
  local lines = resources.transform(scanner.scan(text), file)
  -- Re-scan: the resource pass can change line content but not fence state.
  lines = blocks.transform(scanner.scan(table.concat(lines, "\n")), cfg, file)

  local out = {}
  for _, line in ipairs(scanner.scan(table.concat(lines, "\n"))) do
    out[#out + 1] = line.in_code and line.text or inline.transform(line.text, cfg)
  end
  return table.concat(out, "\n")
end

function Reader(inputs, opts)
  local cfg = config.defaults()
  -- pandoc's ReaderOptions carries only its own fields -- assigning `strict`
  -- to it raises "Cannot set unknown property" -- so a custom reader cannot
  -- receive arbitrary CLI flags through `opts`. bin/markua translates the
  -- documented --lenient and --config flags into the environment instead, and
  -- this is where they land. Without this block both flags are inert.
  if opts and opts.strict == false then
    cfg.strict = false
  end
  if os.getenv("MARKUA_LENIENT") then
    cfg.strict = false
  end
  local cfg_path = os.getenv("MARKUA_CONFIG")
  if cfg_path and cfg_path ~= "" then
    local overrides, err = config.load_file(cfg_path)
    if not overrides then
      error(err, 0)
    end
    cfg = config.merge(cfg, overrides)
  end
  local name = (inputs[1] and inputs[1].name) or "<stdin>"
  local ok, result = pcall(preprocess, tostring(inputs), cfg, name)
  if not ok then
    error(tostring(result), 0)
  end
  return pandoc.read(result, TARGET_FORMAT, opts)
end
```

- [ ] **Step 4: Generate and eyeball the golden files**

```bash
UPDATE=1 ./test/golden.sh
cat test/golden/blurb-tip.native
```

Expected: a `Div` with classes `["tip","blurb"]` containing a `Para`. **Read it before committing** — a golden file generated from broken code locks in the bug.

- [ ] **Step 5: Add the index-entry golden case**

Create `test/golden/index-entries.md`:

```markua
The {ix: "B-tree"} B-tree is a self-balancing tree.

A **token**{i: "token"} is a piece of a word.

Splitting a node {ix: "Trees!B-tree"} keeps the tree balanced.
```

The third entry is the hierarchy case. Both index syntaxes accept `!` as a
level separator, and it is the only construct here whose Word rendering
differs structurally from its source text, so it earns a fixture line.

```bash
UPDATE=1 ./test/golden.sh
grep -c 'index' test/golden/index-entries.native   # expect 2
```

- [ ] **Step 6: Add the golden recipe**

In `justfile`, add the recipe and wire it into `test`:

```just
test: unit golden

# pandoc AST comparison. Regenerate with: UPDATE=1 ./test/golden.sh
golden:
    ./test/golden.sh
```

- [ ] **Step 7: Run the full suite**

Run: `just test`
Expected: all busted specs pass, all golden files match

- [ ] **Step 8: Commit**

```bash
git add src/markua.lua test/golden.sh test/golden/ justfile
git commit -m "feat: pandoc custom reader entry point with golden tests"
```

---

### Task 9a: Code and table resource lowering

**Files:**

- Create: `src/filters/resources.lua`
- Create: `test/filters.sh` — the shared filter-integration harness. This is the
  first filter task, so it creates the harness; Tasks 10, 10a and 11 add their
  assertions to it.

**Interfaces:**

- Consumes: `.code-resource` and `.table-resource` spans from `resources.transform`.
- Produces: a real `CodeBlock` and a real `Table` respectively, so the content reaches every writer instead of rendering as nothing.

Without this filter a manuscript's code samples convert to a book with no code
in it, and the conversion exits 0. Video and audio stay out of scope (see the
out-of-scope list): neither has a print target and pandoc has no native node
for either, so their spans remain annotations for a downstream filter.

- [ ] **Step 1: Write the failing test**

Create `test/filters.sh`. The preamble here is shared: every later filter task
appends its assertions below this block and reuses `$tmp`.

```bash
#!/usr/bin/env bash
# Filter integration tests: build real output and assert on it.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Assert on the native AST, not HTML. A span that merely carries the code as
# text renders "puts" in HTML too, so only the node type proves the lowering
# happened.
printf 'puts "hi"\n' > "$tmp/hello.rb"
printf '![](hello.rb)\n' > "$tmp/code.md"
out=$(pandoc --from=src/markua.lua --to=native \
      --lua-filter=src/filters/resources.lua \
      --resource-path="$tmp" "$tmp/code.md")
case "$out" in
    *CodeBlock*puts*) echo "ok   code resource lowered to a real CodeBlock" ;;
    *) echo "FAIL: code resource did not become a CodeBlock"; exit 1 ;;
esac

# The table branch is a separate code path and needs its own case.
printf 'name,count\nB-tree,3\n' > "$tmp/data.csv"
printf '![](data.csv)\n' > "$tmp/table.md"
out=$(pandoc --from=src/markua.lua --to=native \
      --lua-filter=src/filters/resources.lua \
      --resource-path="$tmp" "$tmp/table.md")
case "$out" in
    *Table*) echo "ok   table resource lowered to a real Table" ;;
    *) echo "FAIL: table resource did not become a Table"; exit 1 ;;
esac

# A missing resource must fail loudly rather than emitting an empty block.
printf '![](nope.rb)\n' > "$tmp/missing.md"
if pandoc --from=src/markua.lua --to=native \
      --lua-filter=src/filters/resources.lua \
      --resource-path="$tmp" "$tmp/missing.md" >/dev/null 2>&1; then
    echo "FAIL: a missing resource converted successfully"; exit 1
fi
echo "ok   missing resource fails loudly"
```

```bash
chmod +x test/filters.sh
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./test/filters.sh`
Expected: FAIL — `src/filters/resources.lua` does not exist

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/filters/resources.lua`:

```lua
--- Lower non-image resource spans into real pandoc blocks.
--
-- resources.transform annotates these but cannot read files: it is pure Lua
-- and runs before pandoc exists. Reading happens here, where PANDOC_STATE
-- makes the resource path available.
local function read_file(src)
  -- Markua allows a resource to be an absolute web URL. Joining one onto a
  -- resource-path directory yields "resources/https://host/x.rb" and fails as a
  -- missing file, which tells the author nothing. Name the case instead.
  -- pandoc.mediabag.fetch is the resolver to reach for if web resources come
  -- into scope; until then this is a clear refusal, not a confusing error.
  if src:match("^https?://") then
    return nil, "web resources are not supported: " .. src
  end
  for _, dir in ipairs(PANDOC_STATE.resource_path or { "." }) do
    local path = (dir == "." and src) or (dir .. "/" .. src)
    local fh = io.open(path, "r")
    if fh then
      local body = fh:read("a")
      fh:close()
      return body
    end
  end
  return nil
end

--- Apply Markua crop-start / crop-end to an already-read body.
local function crop(body, attrs)
  local first = tonumber(attrs["crop-start"])
  local last = tonumber(attrs["crop-end"])
  if not first and not last then
    return body
  end
  local kept, n = {}, 0
  for line in (body .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if (not first or n >= first) and (not last or n <= last) then
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept, "\n")
end

function Para(el)
  -- A resource span is the whole paragraph; pandoc has already wrapped it.
  if #el.content ~= 1 or el.content[1].t ~= "Span" then
    return nil
  end
  local span = el.content[1]
  local src = span.attributes["src"]
  if not src then
    return nil
  end

  if span.classes:includes("code-resource") then
    local body, err = read_file(src)
    if not body then
      error(err or ("cannot read code resource: " .. src), 0)
    end
    local lang = span.attributes["format"] or src:match("%.([%w]+)$") or ""
    return pandoc.CodeBlock(crop(body, span.attributes),
                            pandoc.Attr(span.identifier, { lang }, {}))
  end

  if span.classes:includes("table-resource") then
    local body, err = read_file(src)
    if not body then
      error(err or ("cannot read table resource: " .. src), 0)
    end
    -- Delegate CSV parsing to pandoc rather than hand-rolling quote handling.
    local parsed = pandoc.read(body, "csv")
    return parsed.blocks
  end
end
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `./test/filters.sh`
Expected: three `ok` lines — `code resource lowered to a real CodeBlock`,
`table resource lowered to a real Table`, and `missing resource fails loudly`

- [ ] **Step 5: Wire it into the justfile**

In `justfile`, add the recipe and extend `test`:

```just
test: unit golden filters

# Builds real output through the filters and asserts on it.
filters:
    ./test/filters.sh
```

- [ ] **Step 6: Commit**

```bash
git add src/filters/resources.lua test/filters.sh justfile
git commit -m "feat: lower code and table resources into real blocks"
```

---

### Task 10: Index-to-Word-XE filter

**Files:**

- Create: `src/filters/index-xe.lua`
- Modify: `test/filters.sh` (created by Task 9a)

**Interfaces:**

- Consumes: spans with class `indexref` and attribute `entry`, produced by `inline.transform`. This is exactly the shape pandoc's own Docx reader emits for a Word `XE` field (`Readers/Docx.hs`), so `markua -> docx -> pandoc` round-trips to the identical span.
- Produces: a `Span` filter emitting `RawInline("openxml", ...)` Word field codes. No-ops for non-DOCX output because `RawInline` with an `openxml` format is ignored by other writers.

- [ ] **Step 1: Write the failing test**

Add to `test/filters.sh`, below Task 9a's assertions — the shebang, `set -euo
pipefail`, `$tmp` and its `trap` are already established there:

```bash
pandoc --from=src/markua.lua --to=docx \
    --lua-filter=src/filters/index-xe.lua \
    test/golden/index-entries.md -o "$tmp/out.docx"

unzip -p "$tmp/out.docx" word/document.xml > "$tmp/document.xml"

count=$(grep -o 'XE "' "$tmp/document.xml" | wc -l | tr -d ' ')
if [ "$count" -ne 3 ]; then
    echo "FAIL: expected 3 XE index fields, got $count"; exit 1
fi

# Counting fields does not prove they say the right thing. `Trees!B-tree` must
# reach Word as a subentry (`Trees:B-tree`); a flat entry with a literal bang
# still counts as a field and would pass the check above.
if ! grep -q 'XE "Trees:B-tree"' "$tmp/document.xml"; then
    echo "FAIL: index hierarchy not translated to a Word subentry"; exit 1
fi
echo "ok   index-xe produced $count Word index fields, hierarchy preserved"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./test/filters.sh`
Expected: FAIL — `src/filters/index-xe.lua` does not exist

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/filters/index-xe.lua`:

```lua
--- Turn index spans into real Word XE index fields.
--
-- Word builds a back-of-book index from XE field codes. Pandoc has no
-- native index construct, so the reader annotates index points as spans and
-- this filter lowers them to raw OpenXML. Writers other than docx ignore
-- openxml RawInline, so this filter is safe to always enable.

local function xe_field(term)
  -- Markua spells index hierarchy with `!`; a Word XE field spells it with
  -- `:`. Passing the term through unchanged produces one flat entry named
  -- "Trees!B-tree" instead of a B-tree subentry under Trees, so the documented
  -- hierarchy silently does not survive into the book's index.
  --
  -- Escape a colon or backslash the author actually wrote before translating,
  -- so an existing colon stays literal instead of inventing an index level.
  local escaped = term:gsub("\\", "\\\\"):gsub(":", "\\:")
  escaped = escaped:gsub("!", ":")
  escaped = escaped:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "'")
  return table.concat({
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> XE "', escaped, '" </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
  })
end

function Span(el)
  if el.classes:includes("indexref") and el.attributes["entry"] then
    return pandoc.RawInline("openxml", xe_field(el.attributes["entry"]))
  end
end
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `./test/filters.sh`
Expected: `ok   index-xe produced 3 Word index fields, hierarchy preserved`

The fixture carries three entries — `{ix: "B-tree"}`, `{i: "token"}`, and the
hierarchy case `{ix: "Trees!B-tree"}` — so three is the correct count. The
`filters` recipe is already wired into the justfile by Task 9a.

- [ ] **Step 5: Commit**

```bash
git add src/filters/index-xe.lua test/filters.sh
git commit -m "feat: lower index spans to Word XE index fields"
```

---

### Task 10a: Index filters for LaTeX and DocBook

**Files:**

- Create: `src/filters/index-latex.lua`, `src/filters/index-docbook.lua`

**Carried in from the Task 2/3 review — this task owns it.** XML types `xml:id`
as an `NCName`, which may not begin with a digit, so `{#3things}` is a valid id
for pandoc, HTML and LaTeX but invalid in DocBook and EPUB. pandoc's own DocBook
writer passes such an id through unsanitized, so this is upstream behavior rather
than something the reader introduces, and `attributes.lua` cannot decide it: the
parser does not know the output format. The DocBook filter does. Decide here
whether to sanitize the id, warn, or document it as an authoring constraint --
and note that rejecting it outright would refuse documents the other three
writers handle correctly.

**Interfaces:**

- Consumes: the same `indexref` spans Task 10 consumes.
- Produces: `RawInline("latex", "\\index{...}")` and `RawInline("docbook", "<indexterm>...")` respectively, each a no-op for other writers.

HTML and EPUB need no filter at all: pandoc's HTML writer renders unknown span
attributes as `data-` attributes, so an index span already arrives as
`<span class="indexref" data-entry="B-tree"></span>`. That covers two of the
five promised writers for free, and these two filters cover two more.

- [ ] **Step 1: Write the LaTeX filter**

Create `src/filters/index-latex.lua`:

```lua
--- Lower index spans to LaTeX \index commands.
--
-- Markua and LaTeX happen to spell index hierarchy the same way -- `!` is the
-- subentry separator in both -- so the entry text passes through untouched.
-- Only LaTeX's own specials need escaping.
--
-- A \index command produces no printed index unless the preamble loads
-- makeidx, so this filter injects that once per document. Without it the
-- conversion silently succeeds and the book ships with no index, which is the
-- exact failure this project exists to prevent.
local emitted = false

local ESCAPES = { ["\\"] = "\\textbackslash{}", ["{"] = "\\{", ["}"] = "\\}",
                  ["#"] = "\\#", ["$"] = "\\$", ["%"] = "\\%", ["&"] = "\\&",
                  ["_"] = "\\_", ["^"] = "\\textasciicircum{}" }

local function escape(term)
  -- `!` and `|` are index-syntax operators in LaTeX, not literals. `!` is
  -- deliberately preserved; `|` would start a page-format spec, so quote it.
  return (term:gsub("[\\{}#%$%%&_%^]", ESCAPES):gsub("|", '"|'))
end

function Span(el)
  if el.classes:includes("indexref") and el.attributes["entry"] then
    emitted = true
    return pandoc.RawInline("latex", "\\index{" .. escape(el.attributes["entry"]) .. "}")
  end
end

function Pandoc(doc)
  if not emitted then
    return nil
  end
  local header = doc.meta["header-includes"] or pandoc.MetaList({})
  if header.t ~= "MetaList" then
    header = pandoc.MetaList({ header })
  end
  header[#header + 1] = pandoc.MetaBlocks({
    pandoc.RawBlock("latex", "\\usepackage{makeidx}\n\\makeindex"),
  })
  doc.meta["header-includes"] = header
  return doc
end
```

Filters run `Span` before `Pandoc`, so `emitted` is already correct by the time
the preamble decision is made. `\printindex` stays the author's call: where the
index prints is a layout decision, not something a reader should choose.

- [ ] **Step 2: Write the DocBook filter**

Create `src/filters/index-docbook.lua`:

```lua
--- Lower index spans to DocBook <indexterm> elements.
--
-- pandoc's DocBook *reader* parses <indexterm> into primary/secondary/tertiary
-- attributes, but its writer does not round-trip them, so raw output is the
-- only route. DocBook nests explicitly rather than with a separator, which is
-- why the Markua `!` levels are split apart here.
local LEVELS = { "primary", "secondary", "tertiary" }

local function escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function Span(el)
  if not (el.classes:includes("indexref") and el.attributes["entry"]) then
    return nil
  end
  local parts = {}
  for piece in (el.attributes["entry"] .. "!"):gmatch("(.-)!") do
    parts[#parts + 1] = piece
  end
  local out = { "<indexterm>" }
  for i, piece in ipairs(parts) do
    local tag = LEVELS[i]
    -- DocBook defines exactly three levels; deeper Markua nesting is folded
    -- into the last one rather than dropped.
    if not tag then
      out[#out] = out[#out]:gsub("</tertiary>$", "") .. "!" .. escape(piece) .. "</tertiary>"
    else
      out[#out + 1] = "<" .. tag .. ">" .. escape(piece) .. "</" .. tag .. ">"
    end
  end
  out[#out + 1] = "</indexterm>"
  return pandoc.RawInline("docbook", table.concat(out))
end
```

- [ ] **Step 3: Extend the filter tests**

Add to `test/filters.sh`, after the DOCX assertions:

```bash
tex=$(pandoc --from=src/markua.lua --to=latex \
      --lua-filter=src/filters/index-latex.lua \
      test/golden/index-entries.md)
case "$tex" in
    *'\index{Trees!B-tree}'*) ;;
    *) echo "FAIL: LaTeX index hierarchy not preserved"; exit 1 ;;
esac
case "$tex" in
    *'makeidx'*) ;;
    *) echo "FAIL: makeidx preamble not injected"; exit 1 ;;
esac

db=$(pandoc --from=src/markua.lua --to=docbook \
     --lua-filter=src/filters/index-docbook.lua \
     test/golden/index-entries.md)
case "$db" in
    *'<primary>Trees</primary><secondary>B-tree</secondary>'*) ;;
    *) echo "FAIL: DocBook indexterm nesting wrong"; exit 1 ;;
esac
echo "ok   index lowered for latex and docbook"
```

- [ ] **Step 4: Add the round-trip oracle**

pandoc's Docx reader parses `XE` fields back into exactly the span the reader
emitted, which is a stronger check than grepping XML. Add to `test/filters.sh`:

```bash
rt=$(pandoc --from=docx --to=native "$tmp/out.docx")
case "$rt" in
    *'"indexref"'*'"entry" , "Trees:B-tree"'*) ;;
    *) echo "FAIL: index span did not survive a docx round trip"; exit 1 ;;
esac
echo "ok   index spans round-trip through docx"
```

- [ ] **Step 5: Commit**

```bash
git add src/filters/index-latex.lua src/filters/index-docbook.lua test/filters.sh
git commit -m "feat: lower index spans for latex and docbook"
```

---

### Task 11: Callout-to-Word-style filter

**Files:**

- Create: `src/filters/callouts.lua`
- Modify: `test/filters.sh`

**Interfaces:**

- Consumes: divs with a callout class plus `.blurb`, or class `.aside`, produced by `blocks.transform`
- Produces: a `Div` filter setting `custom-style`, which pandoc's docx writer maps to a named Word paragraph style.

- [ ] **Step 1: Write the failing test**

Append to `test/filters.sh` before the final `echo`:

```bash
pandoc --from=src/markua.lua --to=docx \
    --lua-filter=src/filters/callouts.lua \
    test/golden/blurb-tip.md -o "$tmp/callout.docx"

unzip -p "$tmp/callout.docx" word/document.xml > "$tmp/callout.xml"

if ! grep -q 'w:val="CalloutTip"' "$tmp/callout.xml"; then
    echo "FAIL: expected a CalloutTip paragraph style"; exit 1
fi
echo "ok   callouts produced named Word styles"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./test/filters.sh`
Expected: FAIL — `src/filters/callouts.lua` does not exist

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/filters/callouts.lua`:

```lua
--- Map Markua callouts onto named Word paragraph styles.
--
-- Pandoc's docx writer ignores Div classes, so without this every blurb and
-- aside in a book flattens into ordinary body text. Setting custom-style
-- makes the writer emit a named style that a --reference-doc template can
-- format. Rename the values below to match a publisher's template.

local ASIDE_STYLE = "Aside"

-- Derive the style name from the class the reader already attached, rather
-- than from a hardcoded list. config.lua lets a book override callout_classes,
-- and a duplicated table here would silently no-op on any class outside it --
-- the callout would flatten into body text with no error.
local function style_name(class)
  local words = {}
  for word in class:gmatch("[^%-_]+") do
    words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
  end
  return "Callout " .. table.concat(words, " ")
end

function Div(el)
  -- Check the head class BEFORE the aside fallback. The reader always puts
  -- the callout class first and the .blurb/.aside marker last, so a
  -- callout-classed aside ({.tip .aside}) carries "tip" as its head class
  -- exactly like a blurb does. Testing .aside first -- as this filter once
  -- did -- matches before the head class is ever inspected, losing the tip
  -- and flattening the block to the generic aside style.
  local head = el.classes[1]
  if head and head ~= "aside" and head ~= "blurb" then
    el.attributes["custom-style"] = style_name(head)
    return el
  end
  -- A bare aside ({.aside}, no callout class) has no head class to check.
  if el.classes:includes("aside") then
    el.attributes["custom-style"] = ASIDE_STYLE
    return el
  end
end
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `./test/filters.sh`
Expected: both `ok` lines print

- [ ] **Step 5: Commit**

```bash
git add src/filters/callouts.lua test/filters.sh
git commit -m "feat: map callouts to named Word paragraph styles"
```

---

### Task 12: The `markua` CLI wrapper

**Files:**

- Create: `bin/markua`
- Create: `test/cli.sh`

**Interfaces:**

- Consumes: `src/markua.lua`, both filters
- Produces: `markua [--lenient] [--config <file>] <input.md> -o <output.ext> [pandoc args...]` — resolves the reader and filter paths relative to the script, applies the whole filter set by default (each is a no-op for writers it does not target), translates the two Markua flags into the environment, and passes everything else through to pandoc.

- [ ] **Step 1: Write the failing test**

Create `test/cli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

./bin/markua test/golden/index-entries.md -o "$tmp/out.docx"
[ -s "$tmp/out.docx" ] || { echo "FAIL: empty docx"; exit 1; }

unzip -p "$tmp/out.docx" word/document.xml | grep -q 'XE "' \
    || { echo "FAIL: filters not applied by default"; exit 1; }

./bin/markua test/golden/blurb-tip.md -o "$tmp/out.html"
grep -q 'tip' "$tmp/out.html" || { echo "FAIL: html lost the class"; exit 1; }

echo "ok   cli builds docx and html"
```

```bash
chmod +x test/cli.sh
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `./test/cli.sh`
Expected: FAIL — `./bin/markua` does not exist

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `bin/markua`:

```sh
#!/usr/bin/env sh
# Convert a Markua document with pandoc, using the Markua reader and the
# standard filter set. Any additional arguments are passed to pandoc, so
# --reference-doc, --toc, and friends all work.
set -eu

# CDPATH='' rather than a bare CDPATH= : shellcheck flags the empty-assignment
# form as SC1007, and `just lint` runs shellcheck over every file with no
# severity threshold, so the bare form fails the repo's own gate on commit.
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# The reader runs inside pandoc, which passes it no custom CLI flags -- its
# ReaderOptions object rejects unknown fields. Intercept the two documented
# Markua flags here and hand them to the reader through the environment, which
# is the only channel that survives the pandoc boundary.
export MARKUA_LENIENT="${MARKUA_LENIENT:-}"
export MARKUA_CONFIG="${MARKUA_CONFIG:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --lenient) MARKUA_LENIENT=1; shift ;;
        --config) MARKUA_CONFIG="${2:?--config needs a path}"; shift 2 ;;
        --config=*) MARKUA_CONFIG="${1#--config=}"; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

# Every filter is a no-op for writers it does not target, so applying the whole
# set unconditionally costs nothing and means the right lowering happens for
# whichever -o the user picked.
exec pandoc \
    --from="$root/src/markua.lua" \
    --lua-filter="$root/src/filters/resources.lua" \
    --lua-filter="$root/src/filters/index-xe.lua" \
    --lua-filter="$root/src/filters/index-latex.lua" \
    --lua-filter="$root/src/filters/index-docbook.lua" \
    --lua-filter="$root/src/filters/callouts.lua" \
    "$@"
```

```bash
chmod +x bin/markua
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `./test/cli.sh`
Expected: `ok   cli builds docx and html`

- [ ] **Step 5: Add it to the justfile and commit**

In `justfile`, add the recipe and extend `test`:

```just
test: unit golden filters cli

# Exercises bin/markua end to end.
cli:
    ./test/cli.sh
```

```bash
git add bin/markua test/cli.sh justfile
git commit -m "feat: markua CLI wrapper"
```

---

## Phase 6: Validation against a real book

### Task 13: Whole-book smoke test

**Files:**

- Create: `test/book.sh`
- Create: `README.md` (usage section)

**Interfaces:**

- Consumes: everything
- Produces: a script that converts every file of a real Markua manuscript and asserts no errors, then compares index-marker and resource counts against the source and confirms all five writers complete.

This is where the reader meets syntax the fixtures did not anticipate. Expect to find bugs here and to loop back into earlier tasks.

- [ ] **Step 1: Write the failing test**

Create `test/book.sh`:

```bash
#!/usr/bin/env bash
# Convert every file of a real manuscript. Usage:
#   ./test/book.sh /path/to/book/manuscript
set -uo pipefail

src="${1:-}"
[ -d "$src" ] || { echo "usage: $0 /path/to/manuscript"; exit 2; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; ok=0

for md in "$src"/*.md; do
    if ./bin/markua "$md" --resource-path="$src/resources" \
            -o "$tmp/$(basename "${md%.md}").docx" 2>"$tmp/err"; then
        ok=$((ok+1))
    else
        echo "FAIL $(basename "$md")"; sed 's/^/    /' "$tmp/err"; fail=$((fail+1))
    fi
done

echo "converted: $ok   failed: $fail"

xe=$(for d in "$tmp"/*.docx; do unzip -p "$d" word/document.xml; done \
     | grep -o 'XE "' | wc -l | tr -d ' ')
echo "Word index fields produced: $xe"

[ "$fail" -eq 0 ] || exit 1

# Converting without crashing is not the same as converting correctly. A
# regression that drops every index entry still exits 0 unless this is checked,
# and index preservation is the reason this project exists.
if [ "$xe" -eq 0 ]; then
    echo "FAIL: no Word index fields produced across the whole manuscript"
    exit 1
fi

# A nonzero total is a weak gate: it stays green while most entries vanish.
# Compare against the source instead. Both index syntaxes count, and the
# comparison is >= rather than == because one source marker can legitimately
# produce more than one field after a split.
src_ix=$(grep -oE '\{i x?:|\{ix:|\{i:' "$src"/*.md | wc -l | tr -d ' ')
if [ "$xe" -lt "$src_ix" ]; then
    echo "FAIL: $src_ix index markers in source, only $xe Word fields produced"
    exit 1
fi

# Resource attributes are the other half of the stated differentiator and were
# previously unchecked, so a regression that dropped every one of them passed.
res=$(for d in "$tmp"/*.docx; do unzip -p "$d" word/document.xml; done \
      | grep -c 'w:drawing' | tr -d ' ')
src_res=$(grep -c '^!\[' "$src"/*.md | awk -F: '{s+=$2} END {print s+0}')
if [ "$src_res" -gt 0 ] && [ "$res" -eq 0 ]; then
    echo "FAIL: $src_res resources in source, none survived into the output"
    exit 1
fi
echo "resources embedded: $res (source references: $src_res)"

# The Goal promises five writers. DOCX is asserted above; the rest are checked
# for clean conversion so a writer-specific break cannot hide behind a green
# DOCX run. Deeper per-format preservation is an open question, not a gate.
for fmt in epub latex icml html; do
    for md in "$src"/*.md; do
        ./bin/markua "$md" --resource-path="$src/resources" \
            -o "$tmp/fmt-check.$fmt" 2>"$tmp/err" && continue
        echo "FAIL: $fmt conversion failed on $(basename "$md")"
        sed 's/^/    /' "$tmp/err"
        exit 1
    done
done
echo "ok   all five writers converted the whole manuscript"
```

```bash
chmod +x test/book.sh
```

- [ ] **Step 2: Run it against a real book**

Run: `./test/book.sh ~/Projects/ai_field_guide/manuscript`
Expected: initially some failures, each naming a file and an unhandled construct.

- [ ] **Step 3: Fix each failure by extending the relevant module**

For every failure, add a focused unit test to the module that owns the construct (`blocks_spec.lua`, `inline_spec.lua`, or `resources_spec.lua`), watch it fail, fix the module, watch it pass. Do not patch `src/markua.lua` to special-case a document.

- [ ] **Step 4: Re-run until clean**

Run: `./test/book.sh ~/Projects/ai_field_guide/manuscript`
Expected: `failed: 0`, and a non-zero index-field count

- [ ] **Step 5: Run the whole suite**

Run: `just test`
Expected: all green

- [ ] **Step 6: Write the README**

`README.md` must cover: what the project is, the delegating-reader design and why a native parser was rejected, install (pandoc 3.10+, `luarocks install busted` for development), `bin/markua` usage with a `--reference-doc` example, the supported-construct table, the full out-of-scope list from the section below (quizzes and exercises, smart crosslinks, `Book.txt` assembly, emoji shortcodes, Leanpub document settings), the one-file-per-invocation boundary and what that means for converting a whole book, and how to override callout classes with `--config`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "test: whole-book smoke test and README"
```

---

## Out of scope for v1

Recorded so they are decisions rather than oversights:

- **Quizzes and exercises** (Markua 0.10 course constructs). Rejected with a clear error by Task 8.
- **Smart crosslinks** (`[](#id)` auto-generating link text from the target heading). Requires a second pass over the whole document to resolve titles; the reader is per-file. Add as a filter later.
- **`Book.txt` multi-file assembly.** The reader converts one file at a time; ordering is the caller's job. A `--book` mode in `bin/markua` is the natural follow-up.
- **Video and audio resource lowering.** `resources.lua` still classifies them and emits an annotated span, but no filter lowers that span into a writer construct. Neither has a print target, and pandoc has no native node for either. Code and CSV-table resources *are* lowered (Task 9a).
- **Emoji shortcodes and Font Awesome** (`:joy:`, `:fa-github:`). Pandoc's `emoji` extension covers the first; Font Awesome has no sensible print target.
- **Leanpub document settings** (`bookfilename`, `soft-breaks`). Parsed and ignored; they configure Leanpub's build, not pandoc's.

---

## Deferred / Open Questions

### From the 2026-08-16 spec sweep

- **RESOLVED — Insertion directives are recognized.** The complete Markua 0.30
  bare-word directive set — structural (`frontmatter`, `mainmatter`,
  `backmatter`) and insertion (`pagebreak`, the title-page and front-matter
  inserts, `toc`, `figures`, `tables`, `index`, `exercise-answers`,
  `quiz-answers`) — is now recognized. An insertion directive lowers to a
  self-closing `::: {.insert insert="word"} :::` marker, the bare word carried
  verbatim. The marker is inert until a filter claims it: no currently-scoped
  task consumes `.insert`, so lowering it into an actual generated index, TOC,
  or figure list needs its own task. See
  `docs/plans/2026-08-16-001-feat-block-constructs-and-directives-plan.md`.

- **The fenced `{blockquote}` … `{/blockquote}` form is unhandled and would
  abort a real manuscript** — Task 5 (blocks.lua)

  `spec.txt:6410-6440` documents a fenced blockquote extension in the same
  tier as the fenced `{blurb}` and `{aside}` forms this plan already handles,
  but no task in this or the 2026-08-16 plan recognizes it, so a manuscript
  using it still aborts the conversion. Found by review rather than by either
  plan's own audit, which is reason to treat the remaining directive-adjacent
  surface as unaudited rather than clear. Deliberately deferred to its own
  task.

### From 2026-08-08 review

Five of the six items raised in review were settled and moved to Key Technical
Decisions above. One remains.

- **The architectural bet is falsified only after twelve tasks** — Architecture / Phase 6 (P1, cross-model Codex, confidence 75)

  If representative Markua cannot be expressed in the chosen pandoc extensions, the discovery arrives after the scanner, both transform passes, and all filters are built, forcing rework across the whole layer. A corpus inventory and one end-to-end conversion slice ahead of Phase 1 would surface that risk while it is still cheap. The counter-argument is that the phases are already ordered to build the cheap pure-Lua modules first, and review has since verified the riskiest interface assumptions directly against pandoc 3.10.1 — index span round-tripping, DocBook admonition output, and delimiter escaping all confirmed — which retires much of what the spike would have discovered.
