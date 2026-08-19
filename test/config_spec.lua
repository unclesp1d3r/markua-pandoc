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
