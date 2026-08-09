-- Spec for the fence-aware line scanner (src/markua/scanner.lua).
--
-- Written before the module exists: this unit's TDD cycle starts red. Run
-- with `busted test/scanner_spec.lua` from the repo root --
-- require("src.markua.scanner") resolves through .busted's lpath only from
-- there.
--
-- The first seven scenarios are docs/plan.md Task 2 Step 1's own spec,
-- carried over verbatim so a regression in the corrected module is visible
-- as a failure rather than a silent reclassification. Everything after them
-- covers this plan's three corrections: KTD1 (column-based indentation),
-- KTD2 (line-ending normalization), and KTD3 (the trailing-record round
-- trip) -- plus the remaining fence-boundary cases R4-R5 call for.
local scanner = require("src.markua.scanner")

describe("scanner", function()
  it("marks lines inside fences as code", function()
    local lines = scanner.scan('a\n```python\n{"k": 1}\n```\nb')
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[2].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("captures the fence info string", function()
    local lines = scanner.scan("```$\nx\n```")
    assert.equals("$", lines[1].info)
    assert.equals("open", lines[1].fence)
    assert.equals("close", lines[3].fence)
  end)

  it("only closes on a matching fence marker", function()
    -- a ``` inside a ~~~ block must not close it
    local lines = scanner.scan("~~~text\n```\nstill code\n~~~\nout")
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("numbers lines from one", function()
    local lines = scanner.scan("a\nb")
    assert.equals(1, lines[1].number)
    assert.equals(2, lines[2].number)
  end)

  it("recognises a fence indented up to three spaces", function()
    local lines = scanner.scan("text\n\n   ```json\n   {\"k\": 1}\n   ```\n")
    assert.is_true(lines[3].in_code)
    assert.equals("open", lines[3].fence)
    assert.is_true(lines[4].in_code)
  end)

  it("treats a four-space indented block as code", function()
    -- Without this, "    {timeout: 30}" reads as a Markua attribute list.
    local lines = scanner.scan("Consider:\n\n    {timeout: 30}\n\nDone.\n")
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("does not treat an indented continuation line as code", function()
    -- Four spaces only start a code block after a blank line.
    local lines = scanner.scan("A paragraph\n    wrapped by hand.\n")
    assert.is_false(lines[2].in_code)
  end)

  it("treats a tab-indented line after a blank line as code (KTD1)", function()
    -- A bare space count scores a tab as zero columns, so the reference
    -- scanner missed this. pandoc parses it as CodeBlock.
    local lines = scanner.scan("Consider:\n\n\t{timeout: 30}\n\nDone.\n")
    assert.is_false(lines[1].in_code)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("treats two spaces then a tab as reaching column four (KTD1)", function()
    -- Column 2 plus a tab advances to the next 4-column stop, i.e. column 4.
    local lines = scanner.scan("Consider:\n\n  \t{timeout: 30}\n\nDone.\n")
    assert.is_true(lines[3].in_code)
  end)

  it("treats a tab-indented fence marker as indented code, not a fence (KTD1)", function()
    -- A tab advances to column 4, which is indented code to pandoc, not a
    -- fence -- so this line carries in_code but no fence field at all.
    local lines = scanner.scan("Consider:\n\n\t```\nDone.\n")
    assert.is_true(lines[3].in_code)
    assert.is_nil(lines[3].fence)
  end)

  it("normalizes CRLF line endings while keeping fence and info detection intact (KTD2)", function()
    local lines = scanner.scan('a\r\n```python\r\n{"k": 1}\r\n```\r\nb')
    for _, record in ipairs(lines) do
      assert.is_nil(record.text:find("\r"))
    end
    assert.equals("python", lines[2].info)
    assert.equals("open", lines[2].fence)
    assert.equals("close", lines[4].fence)
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("splits a lone-CR document the same as its LF equivalent (KTD2)", function()
    local cr = scanner.scan("a\rb\rc")
    local lf = scanner.scan("a\nb\nc")
    assert.equals(#lf, #cr)
    for i = 1, #lf do
      assert.equals(lf[i].text, cr[i].text)
      assert.equals(lf[i].in_code, cr[i].in_code)
    end
  end)

  it("round-trips exactly when every record's text is joined with \\n (KTD3, R10)", function()
    local function round_trip(text)
      local lines = scanner.scan(text)
      local parts = {}
      for _, record in ipairs(lines) do
        parts[#parts + 1] = record.text
      end
      return table.concat(parts, "\n")
    end

    assert.equals("a\n", round_trip("a\n"))
    assert.equals("a", round_trip("a"))
    assert.equals("", round_trip(""))
    assert.equals("```\ncode\n```\n", round_trip("```\ncode\n```\n"))
  end)

  it("closes on a longer closing fence but not on a shorter one", function()
    local longer = scanner.scan("```\ncode\n````\nafter")
    assert.equals("close", longer[3].fence)
    assert.is_false(longer[4].in_code)

    local shorter = scanner.scan("````\ncode\n```\nafter")
    assert.is_nil(shorter[3].fence)
    assert.is_true(shorter[3].in_code)
    assert.is_true(shorter[4].in_code)
  end)

  it("does not close an open fence when the delimiter carries an info string", function()
    local lines = scanner.scan("```\ncode\n```text\nstill code\n```\nafter")
    assert.is_nil(lines[3].fence)
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.equals("close", lines[5].fence)
    assert.is_false(lines[6].in_code)
  end)

  it("leaves every remaining line in_code when a fence is never closed", function()
    local lines = scanner.scan("```\na\nb\nc")
    for i = 2, #lines do
      assert.is_true(lines[i].in_code)
    end
  end)
end)
