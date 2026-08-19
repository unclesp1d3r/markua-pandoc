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
