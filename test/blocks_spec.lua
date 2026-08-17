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

-- U2: B> runs and the fenced {blurb} ... {/blurb} form, both syntaxes
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
end)

-- U4: A> runs and the fenced {aside} ... {/aside} form. A bare aside has no
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
