-- Spec for the structured error type (src/markua/errors.lua).
--
-- Written before the module exists: Task 1's TDD cycle starts red. Run with
-- `busted test/errors_spec.lua` from the repo root -- require("src.markua.errors")
-- resolves through stock package.path only from there.
local errors = require("src.markua.errors")

-- errors.warn writes straight to io.stderr, so swapping the handle is the only
-- way to assert the Lenient path actually warned rather than silently returning.
-- Restores the real handle before returning so a failure cannot leak the stub.
-- errors.warn takes an optional sink, so the Lenient path's output can be
-- asserted without swapping the global io.stderr out from under the suite.
local function recording_sink()
  local chunks = {}
  return {
    write = function(_, ...)
      for _, piece in ipairs({ ... }) do
        chunks[#chunks + 1] = piece
      end
    end,
    text = function() return table.concat(chunks) end,
  }
end

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
    -- Assert the raised value, not just that something raised: report must
    -- surface the structured error, not a bare string.
    local ok, err = pcall(errors.report, { strict = true }, "a.md", 1, "boom")
    assert.is_false(ok)
    assert.equals("a.md", err.file)
    assert.equals(1, err.line)
    assert.equals("boom", err.message)
  end)

  it("downgrades to a warning when not strict", function()
    -- Without this path cfg.strict is dead config and --lenient does nothing.
    -- Asserting the written text is what proves the warning fired; checking the
    -- return value alone still passes when the warn call is deleted outright.
    local sink = recording_sink()
    local result = errors.report({ strict = false, sink = sink }, "a.md", 1, "boom")
    assert.is_false(result)
    assert.equals("warning: a.md:1: boom\n", sink.text())
  end)

  it("treats an absent or empty config as strict", function()
    assert.is_false((pcall(errors.report, nil, "a.md", 1, "boom")))
    assert.is_false((pcall(errors.report, {}, "a.md", 1, "boom")))
  end)

  it("treats a non-table config as strict rather than raising a raw index error", function()
    -- A scalar cfg used to reach `cfg.strict` and raise "attempt to index a
    -- number value" from inside this module, masking the real error.
    local ok, err = pcall(errors.report, 5, "a.md", 1, "boom")
    assert.is_false(ok)
    assert.equals("boom", err.message)
  end)

  it("renders a nil line literally instead of raising from __tostring", function()
    -- string.format("%s:%d: %s", ...) raises on a nil line (bad argument #3),
    -- masking the real error. %s with tostring() on each field must not crash.
    local err = errors.new("a.md", nil, "boom")
    assert.equals("a.md:nil: boom", tostring(err))
  end)

  it("renders a non-integer line literally instead of raising from __tostring", function()
    -- The other half of the %d hazard: %d rejects a float outright with
    -- "number has no integer representation".
    assert.equals("a.md:3.5: boom", tostring(errors.new("a.md", 3.5, "boom")))
  end)
end)
