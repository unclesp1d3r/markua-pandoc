-- Structured errors carrying source position.
--
-- Every later module in this reader reports unknown constructs by file and
-- line. A shared error type lets callers inspect `.file` / `.line` directly
-- instead of parsing a rendered string back apart, and gives the documented
-- --lenient flag a single place (report) where the Strict/Lenient choice is
-- made.
local M = {}

local mt = {
  -- %s with tostring() on every field, not %d (docs/plan.md's original
  -- string.format("%s:%d: %s", ...)): %d raises on a nil or non-integer
  -- line, and that secondary error inside __tostring would mask the real
  -- one. CLI-level errors (Task 12) have no natural line number, so nil is
  -- a real input, not a hypothetical.
  __tostring = function(e)
    return string.format("%s:%s: %s", tostring(e.file), tostring(e.line), tostring(e.message))
  end,
}

--- Construct a structured error carrying source position.
function M.new(file, line, message)
  return setmetatable({ file = file, line = line, message = message }, mt)
end

--- Raise the table itself so callers can inspect .file / .line.
function M.raise(file, line, message)
  -- Level 0: Lua prepends position info only to string errors, and this
  -- table already carries its own file/line.
  error(M.new(file, line, message), 0)
end

--- Report without aborting. Used only when config.strict is false, so the
--- documented --lenient flag downgrades hard errors instead of being inert.
function M.warn(file, line, message)
  io.stderr:write("warning: ", tostring(M.new(file, line, message)), "\n")
end

--- Raise when strict, warn otherwise. Every unknown-construct path goes
--- through here so leniency is one decision rather than scattered branches.
function M.report(cfg, file, line, message)
  -- The type check is load-bearing: a nil cfg would raise a nil-index error
  -- and a scalar one ("attempt to index a number value") would raise from
  -- inside this module, masking the very error it was called to report.
  -- Strict is the default for every shape except an explicit strict = false.
  if type(cfg) == "table" and cfg.strict == false then
    M.warn(file, line, message)
    return false
  end
  M.raise(file, line, message)
end

return M
