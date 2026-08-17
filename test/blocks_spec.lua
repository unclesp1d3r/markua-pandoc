-- Spec for the block-construct pass (src/markua/blocks.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run with
-- `busted test/blocks_spec.lua` from the repo root -- require("src.markua.blocks")
-- resolves through .busted's lpath only from there.
--
-- U1 ships only the pass skeleton and the pending attribute-list lifecycle:
-- fence passthrough, the {class: part} heading attach, the index-only
-- passthrough, and every path an unclaimed attribute list can take out of
-- the pending state. Blurbs (U2), the sugar prefixes (U3), asides (U4), and
-- the bare-word directive table (U5) all add branches ahead of this unit's
-- generic "unclaimed attribute list" fallback, so a bare word this pass does
-- not yet recognize -- {pagebreak}, {blurb}, {frontmatter} -- exercises that
-- fallback here rather than the marker each later unit gives it.
local scanner = require("src.markua.scanner")
local config = require("src.markua.config")
local blocks = require("src.markua.blocks")

-- A sink that swallows errors.warn's output so a lenient-mode test does not
-- spew "warning: ..." over the test run's own output.
local function quiet_sink()
  return { write = function() end }
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
    -- B> is not yet a recognized construct in U1, but the attribute list
    -- must still fail to bind across the blank rather than surviving to
    -- (wrongly) attach to it once a later unit adds the B> branch.
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

  it("places a rejected attribute list before the directive line that follows it, under --lenient", function()
    -- {pagebreak} is not yet a recognized directive in U1 (U5 adds the
    -- table), so it falls through the same unclaimed-attribute-list path as
    -- {class: tip} and is itself re-emitted verbatim in turn. What this
    -- pins down is ORDER: the pending list must not be re-emitted after the
    -- directive line that disqualified it.
    local lines = run_lines("{class: tip}\n{pagebreak}\n", lenient_cfg())
    local tip_index, pagebreak_index
    for idx, line in ipairs(lines) do
      if line == "{class: tip}" then
        tip_index = idx
      elseif line == "{pagebreak}" then
        pagebreak_index = idx
      end
    end
    assert.is_truthy(tip_index)
    assert.is_truthy(pagebreak_index)
    assert.is_true(tip_index < pagebreak_index)
  end)

  it("raises in strict mode when an attribute list precedes a directive line", function()
    -- A directive line does not consume a pending list.
    local ok = pcall(run, "{class: tip}\n{pagebreak}\n")
    assert.is_false(ok)
  end)

  it("raises in strict mode when an attribute list precedes a fenced {blurb} opener", function()
    -- Per R13a, a preceding list is illegal above a fenced opener even once
    -- U2 gives {blurb} its own branch; here it is unconsumed for a simpler
    -- reason -- U1 does not recognize it at all yet -- but the outcome the
    -- author sees, a hard error, must already be correct.
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
