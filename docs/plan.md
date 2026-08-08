# Markua Pandoc Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `markua-pandoc`, a pandoc custom reader that parses Markua 0.30 (minus quizzes and exercises) so any Leanpub book can be converted to DOCX, EPUB, LaTeX, ICML, or HTML in one command, preserving index entries and resource attributes that a markdown-to-markdown pipeline structurally cannot carry.

**Architecture:** A *delegating* reader. Markua-only syntax is rewritten in pure Lua into pandoc-flavored markdown (fenced divs, bracketed spans, `$$` math), then handed to `pandoc.read` so pandoc's own parser handles all the CommonMark-shaped work. A second layer of Lua filters turns the resulting AST annotations into output-format-specific constructs (Word `XE` index fields, named paragraph styles). A native from-scratch Markua parser is explicitly out of scope: it would mean reimplementing CommonMark in Lua, which is months of work and worse than pandoc's parser.

**Tech Stack:** Lua 5.4, pandoc 3.10+ (custom reader API, `pandoc.read`, Lua filters), busted for unit tests, shell-driven golden-file tests, LuaRocks for dependency install.

## Global Constraints

- **Target Markua version: 0.30.** Quizzes and exercises (the Markua 0.10 course constructs) are out of scope for v1 and must be rejected with a clear error, not silently dropped.
- **Pandoc 3.10 or newer.** The custom reader API and GitHub-alert parsing both depend on it.
- **No `pandoc` module outside `src/markua.lua` and `src/filters/*.lua`.** busted runs under system Lua, where the `pandoc` global does not exist. Every module under `src/markua/` must be pure Lua and unit-testable without pandoc. This is the single most important structural rule in the plan.
- **Fence-awareness is mandatory in every transform.** Content inside fenced code blocks is never Markua. Real manuscripts contain JSON code blocks whose lines begin with `{`, which a naive attribute-list match will corrupt.
- **Unknown constructs are hard errors.** An unrecognized `{...}` attribute line must abort with file and line number, never pass through as literal braces into the output. A `--lenient` flag may downgrade this to a warning.
- **Lua patterns, not regex.** Lua has no alternation, no lookahead, and no non-greedy `+`. Multi-alternative matching is done with explicit loops over a table of patterns.
- **Two index syntaxes.** `{ix: "term"}` is the Markua spec form and is canonical. `{i: "term"}` is a widespread real-world variant and must also be accepted. `!` creates hierarchy in both (`{ix: "Trees!B-tree"}`).
- **Two blurb syntaxes.** `{class: tip}` on the line above a run of `B>` lines is the spec form. `{blurb, class: tip}` ... `{/blurb}` is the fenced form Leanpub also accepts. Both must work.
- **Blurb/aside classes are configurable, not hardcoded.** The documented set is `warning`, `tip`, `note`, `information`, `error`, `question`, `discussion`, `exercise`, but real Leanpub builds reject `note`, and books restrict the set further. Ship the documented list as a default that a config file can override.

---

## File Structure

```text
markua-pandoc/
├── README.md
├── justfile                        # test, lint, install recipes
├── markua-pandoc-dev-1.rockspec    # busted dependency for `luarocks test`
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
│       └── callouts.lua            # blurb/aside divs -> Word styles
└── test/
    ├── scanner_spec.lua            # busted
    ├── attributes_spec.lua
    ├── blocks_spec.lua
    ├── inline_spec.lua
    ├── resources_spec.lua
    ├── golden.sh                   # pandoc integration tests
    └── golden/
        ├── <name>.md               # Markua input
        └── <name>.native           # expected pandoc AST
```

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

```bash
mkdir -p src/markua src/filters bin test/golden
```

- [ ] **Step 2: Install the Lua toolchain**

busted runs under system Lua and will NOT have pandoc's `pandoc` module. That is intentional and shapes the whole design.

```bash
brew install lua luarocks     # macOS; use your distro's packages on Linux
luarocks install --local busted
echo 'export PATH="$HOME/.luarocks/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
busted --version
```

- [ ] **Step 3: Write the failing test**

Create `test/errors_spec.lua`:

```lua
local errors = require("src.markua.errors")

describe("errors", function()
  it("renders file and line in the message", function()
    local err = errors.new("chapter-01.md", 42, "unknown attribute")
    assert.equals("chapter-01.md:42: unknown attribute", tostring(err))
  end)

  it("raises a structured error rather than a string", function()
    local ok, err = pcall(errors.raise, "a.md", 7, "boom")
    assert.is_false(ok)
    assert.equals(7, err.line)
    assert.equals("a.md", err.file)
    assert.equals("boom", err.message)
  end)

  it("reports fatally when strict", function()
    local ok = pcall(errors.report, { strict = true }, "a.md", 1, "boom")
    assert.is_false(ok)
  end)

  it("downgrades to a warning when not strict", function()
    -- Without this path cfg.strict is dead config and --lenient does nothing.
    local ok, result = pcall(errors.report, { strict = false }, "a.md", 1, "boom")
    assert.is_true(ok)
    assert.is_false(result)
  end)
end)
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `busted test/errors_spec.lua`
Expected: FAIL with "module 'src.markua.errors' not found"

- [ ] **Step 5: Implement the minimal code to make the test pass**

Create `src/markua/errors.lua`:

```lua
--- Structured errors carrying source position.
local M = {}

local mt = {
  __tostring = function(e)
    return string.format("%s:%d: %s", e.file, e.line, e.message)
  end,
}

function M.new(file, line, message)
  return setmetatable({ file = file, line = line, message = message }, mt)
end

function M.raise(file, line, message)
  error(M.new(file, line, message), 0)
end

--- Report without aborting. Used only when config.strict is false, so the
--- documented --lenient flag downgrades hard errors instead of being inert.
function M.warn(file, line, message)
  io.stderr:write("warning: " .. tostring(M.new(file, line, message)) .. "\n")
end

--- Raise when strict, warn otherwise. Every unknown-construct path goes
--- through here so leniency is one decision rather than scattered branches.
function M.report(cfg, file, line, message)
  if cfg and cfg.strict == false then
    M.warn(file, line, message)
    return false
  end
  M.raise(file, line, message)
end

return M
```

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `busted test/errors_spec.lua`
Expected: PASS, 4 successes

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

# Install dev dependencies (busted is a luarocks package, not a mise tool).
install:
    luarocks install --local busted

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

- [ ] **Step 8: Commit**

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

- Consumes: `errors` from Task 1
- Produces: `scanner.scan(text) -> array of line records`. Each record is `{ text = string, number = integer, in_code = boolean, fence = "open"|"close"|nil, info = string|nil }`. `in_code` is true for lines *inside* a fence and for the fence delimiters themselves. `info` carries the fence info string (e.g. `python`, `$`) on the opening fence record.

- [ ] **Step 1: Write the failing test**

Create `test/scanner_spec.lua`:

```lua
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

-- How deep a line is indented, and the text with that indent removed.
local function indent_of(line)
  local spaces = line:match("^( *)")
  return #spaces
end

-- Returns marker and info string if the line opens or closes a fence.
-- CommonMark allows a fence to be indented up to three spaces; at four it is
-- an indented code block instead, which is handled separately below.
local function fence_parts(line)
  if indent_of(line) > 3 then
    return nil
  end
  local body = line:gsub("^ *", "")
  local marker, info = body:match("^(```+)(.*)$")
  if not marker then
    marker, info = body:match("^(~~~+)(.*)$")
  end
  if not marker then
    return nil
  end
  return marker, (info or ""):match("^%s*(.-)%s*$")
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

function M.scan(text)
  local lines = {}
  local open_marker = nil
  local indented = false      -- inside a four-space indented code block
  local prev_blank = true     -- start of document counts as a blank
  local number = 0

  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    local blank = is_blank(line)
    local marker, info = fence_parts(line)
    local record = { text = line, number = number, in_code = open_marker ~= nil }

    if open_marker then
      -- Inside a fence: only a matching closing marker matters.
      if marker and marker:sub(1, 1) == open_marker:sub(1, 1)
         and #marker >= #open_marker and info == "" then
        record.fence = "close"
        open_marker = nil
      end
    elseif marker then
      open_marker = marker
      indented = false
      record.in_code = true
      record.fence = "open"
      record.info = info
    else
      -- An indented code block starts on a four-space indent after a blank
      -- line, and runs until a non-blank line dedents. Without this, a code
      -- sample such as "    {timeout: 30}" reads as a Markua attribute list
      -- and gets rewritten -- the same corruption fences protect against.
      if indented then
        if blank then
          record.in_code = true          -- blank lines do not end the block
        elseif indent_of(line) >= 4 then
          record.in_code = true
        else
          indented = false
        end
      elseif prev_blank and not blank and indent_of(line) >= 4 then
        indented = true
        record.in_code = true
      end
    end

    if not blank then
      prev_blank = false
    else
      prev_blank = true
    end

    lines[#lines + 1] = record
  end

  return lines
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/scanner_spec.lua`
Expected: PASS, 7 successes

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
local attributes = require("src.markua.attributes")

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
-- blocks.lua and resources.lua interpret them.
local errors = require("src.markua.errors")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_attribute_line(text)
  local t = trim(text)
  return t:sub(1, 1) == "{" and t:sub(-1) == "}" and #t >= 2
end

-- Split on commas that are not inside double quotes.
local function split_fields(body)
  local fields, buf, in_quote = {}, {}, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '"' then
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

function M.parse(text, file, line)
  local t = trim(text)
  local body = t:match("^{(.*)}$")
  if not body then
    errors.raise(file, line, "not an attribute list: " .. t)
  end

  local parsed = { id = nil, classes = {}, keyvals = {}, bare = {} }

  for _, field in ipairs(split_fields(body)) do
    local f = trim(field)
    if f ~= "" then
      local key, value = f:match("^([%w%-_]+)%s*:%s*(.*)$")
      if key then
        value = unquote(trim(value))
        if key == "class" then
          parsed.classes[#parsed.classes + 1] = value
        else
          parsed.keyvals[key] = value
        end
      elseif f:sub(1, 1) == "#" then
        parsed.id = f:sub(2)
      elseif f:sub(1, 1) == "." then
        parsed.classes[#parsed.classes + 1] = f:sub(2)
      else
        parsed.bare[#parsed.bare + 1] = f
      end
    end
  end

  return parsed
end

function M.to_pandoc_attr(parsed)
  local parts = {}
  if parsed.id then
    parts[#parts + 1] = "#" .. parsed.id
  end
  for _, c in ipairs(parsed.classes) do
    parts[#parts + 1] = "." .. c
  end
  local keys = {}
  for k in pairs(parsed.keyvals) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format('%s="%s"', k, parsed.keyvals[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/attributes_spec.lua`
Expected: PASS, 7 successes

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
- Produces: `config.defaults() -> table` with `callout_classes` (array), `strict` (boolean), `index_keys` (array). `config.merge(base, overrides) -> table`. `config.is_callout_class(cfg, name) -> boolean`.

The documented Markua class set includes `note`, but real Leanpub builds reject it, so books override this list. It must be data, not a hardcoded branch.

- [ ] **Step 1: Write the failing test**

Create `test/config_spec.lua`:

```lua
local config = require("src.markua.config")

describe("config", function()
  it("ships the documented Markua class set", function()
    local cfg = config.defaults()
    assert.is_true(config.is_callout_class(cfg, "warning"))
    assert.is_true(config.is_callout_class(cfg, "discussion"))
    assert.is_false(config.is_callout_class(cfg, "nonsense"))
  end)

  it("accepts both index keys", function()
    assert.same({ "ix", "i" }, config.defaults().index_keys)
  end)

  it("lets a book override the class list", function()
    local cfg = config.merge(config.defaults(), { callout_classes = { "tip" } })
    assert.is_true(config.is_callout_class(cfg, "tip"))
    assert.is_false(config.is_callout_class(cfg, "note"))
  end)

  it("defaults to strict", function()
    assert.is_true(config.defaults().strict)
  end)
end)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `busted test/config_spec.lua`
Expected: FAIL with "module 'src.markua.config' not found"

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `src/markua/config.lua`:

```lua
--- Reader configuration.
local M = {}

function M.defaults()
  return {
    -- The documented Markua set. Note that Leanpub itself rejects `note`
    -- in some builds, so books commonly narrow this list.
    callout_classes = {
      "warning", "tip", "note", "information",
      "error", "question", "discussion", "exercise",
    },
    -- `ix` is the spec form; `i` is a common real-world variant.
    index_keys = { "ix", "i" },
    strict = true,
  }
end

function M.merge(base, overrides)
  local out = {}
  for k, v in pairs(base) do
    out[k] = v
  end
  for k, v in pairs(overrides or {}) do
    out[k] = v
  end
  return out
end

function M.is_callout_class(cfg, name)
  for _, c in ipairs(cfg.callout_classes) do
    if c == name then
      return true
    end
  end
  return false
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/config_spec.lua`
Expected: PASS, 4 successes

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
- Produces: `blocks.transform(lines, cfg, file) -> array of strings`. Input is scanner records; output is pandoc-markdown lines. Blurbs and asides become fenced divs (`::: {.tip .blurb}` … `:::`), matter directives become fenced divs (`::: {.frontmatter}` … `:::` is *not* used; they emit `::: {.matter matter="front"}` self-closing markers), `{class: part}` attaches to the following heading.

- [ ] **Step 1: Write the failing test**

Create `test/blocks_spec.lua`:

```lua
local scanner = require("src.markua.scanner")
local config = require("src.markua.config")
local blocks = require("src.markua.blocks")

local function run(text)
  return table.concat(blocks.transform(scanner.scan(text), config.defaults(), "f.md"), "\n")
end

describe("blocks.transform", function()
  it("converts B> blurbs with a class into fenced divs", function()
    local out = run("{class: tip}\nB> Press Ctrl-R.\n")
    assert.is_truthy(out:find("::: {.tip .blurb}", 1, true))
    assert.is_truthy(out:find("Press Ctrl%-R%."))
    assert.is_truthy(out:find(":::", 1, true))
  end)

  it("converts the fenced blurb form", function()
    local out = run("{blurb, class: warning}\nBack up first.\n{/blurb}\n")
    assert.is_truthy(out:find("::: {.warning .blurb}", 1, true))
  end)

  it("converts A> asides", function()
    local out = run("A> ### Why\nA>\nA> Because.\n")
    assert.is_truthy(out:find("::: {.aside}", 1, true))
    assert.is_truthy(out:find("### Why", 1, true))
  end)

  it("attaches {class: part} to the following heading", function()
    local out = run("{class: part}\n# Foundations\n")
    assert.is_truthy(out:find("# Foundations {.part}", 1, true))
  end)

  it("never transforms inside code fences", function()
    local out = run('```json\n{"class": "tip"}\n```\n')
    assert.is_truthy(out:find('{"class": "tip"}', 1, true))
    assert.is_nil(out:find(":::", 1, true))
  end)

  it("rejects an unknown callout class", function()
    local ok, err = pcall(run, "{class: bogus}\nB> x\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("bogus", 1, true))
  end)

  it("accepts a decorative class alongside the callout class", function()
    local out = run("{.wide, class: tip}\nB> hi\n")
    assert.is_truthy(out:find(".tip", 1, true))
  end)

  it("rejects an attribute list that precedes a plain paragraph", function()
    -- The B> path already raises; this one used to leak "{.bogus}" into the
    -- output as literal text, which is the corruption hard errors exist to stop.
    local ok, err = pcall(run, "{class: bogus}\nJust a paragraph.\n")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("bogus", 1, true))
  end)

  it("rejects an attribute list left unconsumed at end of input", function()
    local ok = pcall(run, "Some intro text.\n\n{class: tip}")
    assert.is_false(ok)
  end)

  it("rejects a second attribute list that would shadow the first", function()
    local ok = pcall(run, '{title: "x"}\n{class: tip}\nB> hello\n')
    assert.is_false(ok)
  end)

  it("passes a standalone index line through untouched", function()
    -- inline.transform runs after this pass and owns index markers. Claiming
    -- it here would render {ix="B-tree"} as visible text in the book.
    local out = run('{ix: "B-tree"}\n\nB-trees are fast.\n')
    assert.is_truthy(out:find('{ix: "B-tree"}', 1, true))
  end)

  it("never transforms B> or {/blurb} inside a code fence", function()
    local out = run("```markua\nB> not a blurb\n{/blurb}\n```\n")
    assert.is_truthy(out:find("B> not a blurb", 1, true))
    assert.is_nil(out:find(":::", 1, true))
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
local attributes = require("src.markua.attributes")
local config = require("src.markua.config")
local errors = require("src.markua.errors")

local M = {}

local MATTER = { frontmatter = true, mainmatter = true, backmatter = true }

local function strip_prefix(text, prefix)
  local body = text:sub(#prefix + 1)
  return (body:gsub("^ ", ""))
end

-- Pull the callout class out of a pending attribute list, validating it.
-- A list may legitimately carry decorative classes alongside the callout one
-- ({.wide, class: tip}), so every class is considered before rejecting.
local function callout_class(pending, cfg, file, line)
  if #pending.classes == 0 then
    return nil
  end
  for _, c in ipairs(pending.classes) do
    if config.is_callout_class(cfg, c) then
      return c
    end
  end
  errors.raise(file, line,
    "unknown callout class '" .. table.concat(pending.classes, "', '") .. "'")
end

-- An attribute list holding only index keys belongs to inline.transform, which
-- runs after this pass. Re-emit it untouched rather than treating it as a
-- pending block attribute, or a standalone {ix: "term"} line would surface as
-- literal text in the finished book.
local function is_index_only(parsed, cfg)
  if parsed.id or #parsed.classes > 0 or #parsed.bare > 0 then
    return false
  end
  local count = 0
  for key in pairs(parsed.keyvals) do
    local known = false
    for _, index_key in ipairs(cfg.index_keys) do
      if key == index_key then
        known = true
      end
    end
    if not known then
      return false
    end
    count = count + 1
  end
  return count > 0
end

function M.transform(lines, cfg, file)
  local out = {}
  local pending = nil        -- attribute list awaiting its element
  local pending_line = nil
  local pending_text = nil   -- the raw line, for verbatim re-emission
  local i = 1

  local function emit(s)
    out[#out + 1] = s
  end

  -- Nothing may consume an attribute list and quietly forget it. Every exit
  -- from the pending state goes through here, so an unclaimed list aborts with
  -- its own line number instead of leaking braces into the book or vanishing.
  local function reject_pending(reason)
    if not pending then
      return
    end
    local text = pending_text
    errors.report(cfg, file, pending_line,
      (reason or "attribute list applies to nothing") .. ": " .. text)
    -- Only reached when cfg.strict is false. Re-emit verbatim: leniency should
    -- preserve the author's text, never silently delete it.
    emit(text)
    pending, pending_line, pending_text = nil, nil, nil
  end

  while i <= #lines do
    local rec = lines[i]
    local text = rec.text

    if rec.in_code then
      emit(text)
      i = i + 1

    elseif attributes.is_attribute_line(text) then
      local parsed = attributes.parse(text, file, rec.number)

      if #parsed.bare == 1 and MATTER[parsed.bare[1]] then
        emit("::: {.matter matter=\"" .. parsed.bare[1] .. "\"}")
        emit(":::")
        i = i + 1
      elseif #parsed.bare == 1 and parsed.bare[1] == "blurb" then
        -- Fenced blurb: consume until {/blurb}
        local class = callout_class(parsed, cfg, file, rec.number) or "information"
        emit("::: {." .. class .. " .blurb}")
        i = i + 1
        -- A code example inside the blurb can legitimately contain {/blurb};
        -- only a line outside a fence terminates it.
        local function is_blurb_end(r)
          return not r.in_code and r.text:match("^%s*{/blurb}%s*$") ~= nil
        end
        while i <= #lines and not is_blurb_end(lines[i]) do
          emit(lines[i].text)
          i = i + 1
        end
        if i > #lines then
          errors.raise(file, rec.number, "unclosed {blurb}")
        end
        emit(":::")
        i = i + 1
      elseif is_index_only(parsed, cfg) then
        reject_pending()
        emit(text)                     -- verbatim; inline.transform owns it
        i = i + 1
      else
        reject_pending()               -- a new list may not shadow an unused one
        pending, pending_line, pending_text = parsed, rec.number, text
        i = i + 1
      end

    elseif text:match("^B>") then
      local class = pending and callout_class(pending, cfg, file, pending_line) or "information"
      emit("::: {." .. class .. " .blurb}")
      while i <= #lines and lines[i].text:match("^B>") do
        emit(strip_prefix(lines[i].text, "B>"))
        i = i + 1
      end
      emit(":::")
      pending, pending_line, pending_text = nil, nil, nil

    elseif text:match("^A>") then
      emit("::: {.aside}")
      while i <= #lines and lines[i].text:match("^A>") do
        emit(strip_prefix(lines[i].text, "A>"))
        i = i + 1
      end
      emit(":::")
      pending, pending_line, pending_text = nil, nil, nil

    else
      if pending and text:match("^#+%s") then
        emit(text .. " " .. attributes.to_pandoc_attr(pending))
        pending, pending_line, pending_text = nil, nil, nil
      elseif pending and text:match("^%s*$") then
        emit(text)   -- keep looking; blank lines do not clear a pending list
      else
        -- resources.transform already ran, so nothing downstream will claim
        -- this. Rendering it through to_pandoc_attr would drop bare words and
        -- leak braces into the output; both are silent corruption.
        reject_pending("attribute list precedes no element it can apply to")
        emit(text)
      end
      i = i + 1
    end
  end

  -- A list in the final position still applies to nothing.
  reject_pending("attribute list at end of input")

  return out
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/blocks_spec.lua`
Expected: PASS, 12 successes

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
- Produces: `inline.transform(text, cfg) -> string`. Rewrites index markers to bracketed spans, `^x^` to pandoc superscript, `~x~` to subscript, and backtick-dollar inline math to `$...$`. Operates on a single line of prose and is only ever called on lines where `in_code` is false.

- [ ] **Step 1: Write the failing test**

Create `test/inline_spec.lua`:

```lua
local config = require("src.markua.config")
local inline = require("src.markua.inline")

local cfg = config.defaults()

describe("inline.transform", function()
  it("converts spec-form index markers to bracketed spans", function()
    local out = inline.transform('The {ix: "B-tree"} B-tree is fast.', cfg)
    assert.equals('The []{.index entry="B-tree"} B-tree is fast.', out)
  end)

  it("also accepts the {i:} variant", function()
    local out = inline.transform('A **token**{i: "token"} here.', cfg)
    assert.equals('A **token**[]{.index entry="token"} here.', out)
  end)

  it("preserves index hierarchy", function()
    local out = inline.transform('{ix: "Trees!B-tree"}x', cfg)
    assert.equals('[]{.index entry="Trees!B-tree"}x', out)
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
    assert.equals('The []{.index entry="100% coverage"} matters.', out)
  end)

  it("does not double a percent sign in inline math", function()
    assert.equals("Value $a % b$ here.", inline.transform("Value `a % b`$ here.", cfg))
  end)

  it("tolerates a space before the colon", function()
    -- attributes.lua accepts "{ix : ...}", so this pass must not disagree.
    local out = inline.transform('A {ix : "term"} here.', cfg)
    assert.equals('A []{.index entry="term"} here.', out)
  end)

  it("converts two index markers on one line", function()
    local out = inline.transform('{ix: "a"} and {ix: "b"}', cfg)
    assert.equals('[]{.index entry="a"} and []{.index entry="b"}', out)
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

function M.transform(text, cfg)
  -- Index markers: {ix: "term"} and the {i: "term"} variant.
  -- Lua has no alternation, so loop over the configured keys. %s* after the
  -- key mirrors attributes.lua, which tolerates "{ix : ...}".
  for _, key in ipairs(cfg.index_keys) do
    local pattern = "{" .. key .. '%s*:%s*"([^"]*)"%s*}'
    text = text:gsub(pattern, function(term)
      return '[]{.index entry="' .. term .. '"}'
    end)
  end

  -- Inline math: `expr`$ becomes $expr$
  text = text:gsub("`([^`]-)`%$", function(expr)
    return "$" .. expr .. "$"
  end)

  return text
end

return M
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `busted test/inline_spec.lua`
Expected: PASS, 10 successes

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

- Consumes: `attributes`, `errors`
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
    local out = run('{crop-start-line: 10, crop-end-line: 42}\n![](code/cli.rb)\n')
    assert.is_truthy(out:find('crop-start-line="10"', 1, true))
  end)

  it("accepts legacy leanpub-start-line as an alias", function()
    local out = run('{leanpub-start-line: 3}\n![](code/cli.rb)\n')
    assert.is_truthy(out:find('crop-start-line="3"', 1, true))
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
  mp4 = "video", webm = "video",
  mp3 = "audio", m4a = "audio",
  csv = "table",
  tex = "math",
}

local LEGACY_ALIAS = {
  ["leanpub-start-line"] = "crop-start-line",
  ["leanpub-end-line"] = "crop-end-line",
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
        if pending and text:match("^%s*$") then
          out[#out + 1] = text
        else
          flush_pending()
          out[#out + 1] = text
        end
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
Expected: PASS, 15 successes

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
  "tex_math_dollars", "backtick_code_blocks", "fenced_code_attributes",
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
  if opts and opts.strict == false then
    cfg.strict = false
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
```

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

### Task 10: Index-to-Word-XE filter

**Files:**

- Create: `src/filters/index-xe.lua`
- Create: `test/filters.sh`

**Interfaces:**

- Consumes: spans with class `index` and attribute `entry`, produced by `inline.transform`
- Produces: a `Span` filter emitting `RawInline("openxml", ...)` Word field codes. No-ops for non-DOCX output because `RawInline` with an `openxml` format is ignored by other writers.

- [ ] **Step 1: Write the failing test**

Create `test/filters.sh`:

```bash
#!/usr/bin/env bash
# Filter integration tests: build a DOCX and assert on its XML.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pandoc --from=src/markua.lua --to=docx \
    --lua-filter=src/filters/index-xe.lua \
    test/golden/index-entries.md -o "$tmp/out.docx"

unzip -p "$tmp/out.docx" word/document.xml > "$tmp/document.xml"

count=$(grep -o 'XE "' "$tmp/document.xml" | wc -l | tr -d ' ')
if [ "$count" -ne 2 ]; then
    echo "FAIL: expected 2 XE index fields, got $count"; exit 1
fi
echo "ok   index-xe produced $count Word index fields"
```

```bash
chmod +x test/filters.sh
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
  local escaped = term:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "'")
  return table.concat({
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve"> XE "', escaped, '" </w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
  })
end

function Span(el)
  if el.classes:includes("index") and el.attributes["entry"] then
    return pandoc.RawInline("openxml", xe_field(el.attributes["entry"]))
  end
end
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `./test/filters.sh`
Expected: `ok   index-xe produced 2 Word index fields`

- [ ] **Step 5: Wire it into the justfile**

In `justfile`, add the recipe and extend `test`:

```just
test: unit golden filters

# Builds real DOCX files and asserts on their XML.
filters:
    ./test/filters.sh
```

- [ ] **Step 6: Commit**

```bash
git add src/filters/index-xe.lua test/filters.sh justfile
git commit -m "feat: lower index spans to Word XE index fields"
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
  if el.classes:includes("aside") then
    el.attributes["custom-style"] = ASIDE_STYLE
    return el
  end
  -- The reader marks every blurb with .blurb plus its callout class.
  if el.classes:includes("blurb") then
    for _, class in ipairs(el.classes) do
      if class ~= "blurb" then
        el.attributes["custom-style"] = style_name(class)
        return el
      end
    end
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
- Produces: `markua <input.md> -o <output.ext> [pandoc args...]` — resolves the reader and filter paths relative to the script, applies both filters by default, and passes everything else through to pandoc.

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

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

exec pandoc \
    --from="$root/src/markua.lua" \
    --lua-filter="$root/src/filters/index-xe.lua" \
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
- Produces: a script that converts every file of a real Markua manuscript and asserts no errors, plus counts of preserved constructs.

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

`README.md` must cover: what the project is, the delegating-reader design and why a native parser was rejected, install (pandoc 3.10+, `luarocks install busted` for development), `bin/markua` usage with a `--reference-doc` example, the supported-construct table, the out-of-scope list (quizzes, exercises), and how to override callout classes.

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
- **Emoji shortcodes and Font Awesome** (`:joy:`, `:fa-github:`). Pandoc's `emoji` extension covers the first; Font Awesome has no sensible print target.
- **Leanpub document settings** (`bookfilename`, `soft-breaks`). Parsed and ignored; they configure Leanpub's build, not pandoc's.
