--- Reader configuration: documented defaults and book-level overrides.
--
-- Pure data plus the lookups the rest of the pipeline needs. No pandoc global
-- here, per AGENTS.md -- busted runs under system Lua, where it does not exist.
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
