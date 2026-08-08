-- Spec for the structured error type (src/markua/errors.lua).
--
-- Written before the module exists: Task 1's TDD cycle starts red. Run with
-- `busted test/errors_spec.lua` from the repo root -- require("src.markua.errors")
-- resolves through stock package.path only from there.
local errors = require("src.markua.errors")

describe("errors", function()
  it("renders file and line in the message", function()
    local err = errors.new("chapter-01.md", 42, "unknown attribute")
    assert.equals("chapter-01.md:42: unknown attribute", tostring(err))
  end)

  it("raises a structured error rather than a string", function()
    local ok, err = pcall(errors.raise, "a.md", 7, "boom")
    assert.is_false(ok)
    assert.equals("a.md", err.file)
    assert.equals(7, err.line)
    assert.equals("boom", err.message)
  end)

  it("reports fatally when strict", function()
    local ok = pcall(errors.report, { strict = true }, "a.md", 1, "boom")
    assert.is_false(ok)
  end)

  it("downgrades to a warning when not strict", function()
    -- Without this path cfg.strict is dead config and --lenient does nothing.
    local ok, result = pcall(errors.report, { strict = false }, "a.md", 1, "boom")
    assert.is_true(ok)
    assert.is_false(result)
  end)

  it("renders a nil line literally instead of raising from __tostring", function()
    -- KTD8: string.format("%s:%d: %s", ...) raises on a nil line, masking the
    -- real error. %s with tostring() on each field must not crash here.
    local err = errors.new("a.md", nil, "boom")
    assert.equals("a.md:nil: boom", tostring(err))
  end)
end)
