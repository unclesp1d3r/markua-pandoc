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
