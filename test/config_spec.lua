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
    assert.is_string(err)
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
