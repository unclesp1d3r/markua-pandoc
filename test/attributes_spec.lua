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

  it("backslash-escapes a quote in a value so pandoc parses it back intact (KTD4)", function()
    -- Verified against pandoc 3.10.1: title="He said \"hi\"" parses to the
    -- value `He said "hi"`. The unescaped form does not degrade to a wrong
    -- title -- pandoc abandons the whole construct and renders the `:::`
    -- delimiters as literal paragraph text.
    local a = { id = nil, classes = {}, keyvals = { title = 'He said "hi"' }, bare = {} }
    assert.equals('{title="He said \\"hi\\""}', attributes.to_pandoc_attr(a))
  end)

  it("escapes a backslash in a value (KTD4)", function()
    -- pandoc spells a literal backslash as title="a\\b"; escape \ before "
    -- so the quote pass does not double-escape the backslashes it introduces.
    local a = { id = nil, classes = {}, keyvals = { path = "a\\b" }, bare = {} }
    assert.equals('{path="a\\\\b"}', attributes.to_pandoc_attr(a))
  end)

  it("orders emitted keyvals deterministically across repeated calls (R18)", function()
    local a = { id = nil, classes = {}, keyvals = { zeta = "1", alpha = "2" }, bare = {} }
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
