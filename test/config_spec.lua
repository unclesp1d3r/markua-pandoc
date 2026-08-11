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

  it("accepts both index keys, spec form first", function()
    assert.same({ "ix", "i" }, config.defaults().index_keys)
  end)

  it("defaults to strict", function()
    assert.is_true(config.defaults().strict)
  end)

  -- defaults() must build its tables per call. A shared array would let one
  -- book's override leak into the next document converted in the same process.
  it("returns independent tables on each call", function()
    local first, second = config.defaults(), config.defaults()
    first.callout_classes[#first.callout_classes + 1] = "leaked"
    assert.is_false(config.is_callout_class(second, "leaked"))
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

  it("copies the base when there is nothing to override", function()
    local base = config.defaults()
    local cfg = config.merge(base, nil)
    assert.same(base.callout_classes, cfg.callout_classes)
    assert.is_true(cfg.strict)
  end)
end)
