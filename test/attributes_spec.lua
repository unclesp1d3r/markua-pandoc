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
    local a = { id = nil, classes = {}, keyvals = { title = 'He said "hi"' }, bare = {} }
    assert.equals([[{title='He said "hi"'}]], attributes.to_pandoc_attr(a))
  end)

  it("keeps double quotes for a value containing only an apostrophe", function()
    local a = { id = nil, classes = {}, keyvals = { title = "it's" }, bare = {} }
    assert.equals([[{title="it's"}]], attributes.to_pandoc_attr(a))
  end)

  it("raises for a value carrying both quote characters", function()
    -- Neither quoting style can enclose it and no escape is available, so
    -- this is unrepresentable rather than silently corrupted.
    local a = { id = nil, classes = {}, keyvals = { title = [[He said "hi" and it's]] }, bare = {} }
    assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 3))
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
    local a = { id = nil, classes = { "3things" }, keyvals = {}, bare = {} }
    assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 1))
  end)

  it("rejects a name carrying punctuation outside pandoc's set", function()
    for _, name in ipairs({ "a&b", "a%b", "a#b", "a<b>c" }) do
      local a = { id = name, classes = {}, keyvals = {}, bare = {} }
      assert.is_false(pcall(attributes.to_pandoc_attr, a, "f.md", 1),
        "expected " .. name .. " to be rejected as an id")
    end
  end)

  it("accepts colon, dot and a leading dash in an id", function()
    local a = { id = "a:b.c", classes = {}, keyvals = {}, bare = {} }
    assert.equals("{#a:b.c}", attributes.to_pandoc_attr(a))
    local dashed = { id = "--x", classes = {}, keyvals = {}, bare = {} }
    assert.equals("{#--x}", attributes.to_pandoc_attr(dashed))
  end)

  it("accepts a non-ASCII name, which pandoc's Unicode alphaNum allows", function()
    local a = { id = "caf\195\169", classes = { "na\195\175ve" }, keyvals = {}, bare = {} }
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
