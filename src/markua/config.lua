--- Reader configuration: documented defaults and book-level overrides.
--
-- Pure data plus the lookups the rest of the pipeline needs. No pandoc global
-- here, per AGENTS.md -- busted runs under system Lua, where it does not exist.
--
-- A book narrows the documented class list through a `--config` file, which
-- `load_file` reads as data rather than running as a program.
--
-- The shape this module defines is already load-bearing: `errors.report` reads
-- `cfg.strict` and `cfg.sink`, blocks.lua asks `is_callout_class`, and
-- inline.lua iterates `index_keys`.
local M = {}

--- The reader's built-in configuration. Constructs fresh tables per call, so
--- one document's override cannot leak into the next one converted in the same
--- process.
function M.defaults()
  return {
    -- The documented Markua 0.30 set. Leanpub itself rejects `note` in some
    -- builds and individual books narrow the list further, which is exactly
    -- why this is data a config file can replace rather than a branch.
    callout_classes = {
      "warning", "tip", "note", "information",
      "error", "question", "discussion", "exercise",
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
-- eight to exactly `tip`, so a value replaces rather than accumulates.
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
  return out
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
-- This is not a defense against resource exhaustion -- concatenation and `for`
-- are VM primitives that need no globals -- and it is not meant to be. The
-- file is the author's own; see the plan's Risks section.
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
  return result
end

--- Is `name` one of the configured callout classes?
--
-- A linear scan over at most eight entries. Building a set would cost more in
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

return M
