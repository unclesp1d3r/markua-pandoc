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
    -- The round trip reproduces the NORMALIZED input, so CRLF in means LF out.
    assert.equals("a\nb\n", round_trip("a\r\nb\r\n"))
  end)

  it("numbers the trailing record one past the last real line (KTD3)", function()
    -- The sentinel record exists only for newline-terminated input, and its
    -- number names no line an author can open. Later modules report error
    -- positions straight from record.number, so pin both halves here.
    local terminated = scanner.scan("a\nb\n")
    assert.equals(3, #terminated)
    assert.equals(3, terminated[3].number)
    assert.equals("", terminated[3].text)

    local unterminated = scanner.scan("a\nb")
    assert.equals(2, #unterminated)
    assert.equals(2, unterminated[2].number)
  end)

  it("closes on a longer closing fence but not on a shorter one", function()
    local longer = scanner.scan("```\ncode\n````\nafter")
    assert.equals("close", longer[3].fence)
    assert.is_false(longer[4].in_code)

    -- A shorter delimiter does not close, so this fence never closes -- and
    -- an unclosed fence is not a fence under the reader's target format, so
    -- the whole run reverts to prose. Verified: pandoc parses this as one
    -- Para containing inline Code, not a CodeBlock.
    local shorter = scanner.scan("````\ncode\n```\nafter")
    assert.is_nil(shorter[3].fence)
    assert.is_false(shorter[3].in_code)
    assert.is_false(shorter[4].in_code)
  end)

  it("does not close an open fence when the delimiter carries an info string", function()
    local lines = scanner.scan("```\ncode\n```text\nstill code\n```\nafter")
    assert.is_nil(lines[3].fence)
    assert.is_true(lines[3].in_code)
    assert.is_true(lines[4].in_code)
    assert.equals("close", lines[5].fence)
    assert.is_false(lines[6].in_code)
  end)

  it("treats a fence that never closes as prose, not code", function()
    -- markdown_strict and its extensions -- the format the reader hands to
    -- pandoc.read -- require a fence to close before it is a fence at all;
    -- an unclosed one is literal text. commonmark and gfm instead run the
    -- block to EOF. Following the target format is what keeps this scanner's
    -- answer and pandoc's identical, which is the module's whole job.
    local lines = scanner.scan("```\na\nb\nc")
    for i = 1, #lines do
      assert.is_false(lines[i].in_code)
    end
    assert.is_nil(lines[1].fence)
  end)

  it("reverts an unclosed fence inside a blockquote when the quote ends", function()
    local lines = scanner.scan("> ```\n> quoted\n\nafter\n")
    assert.is_false(lines[1].in_code)
    assert.is_false(lines[2].in_code)
    assert.is_false(lines[4].in_code)
  end)
end)

-- Every expectation below is pandoc 3.10.1's own answer for the same input,
-- taken under the exact format the reader hands to pandoc.read
-- (markdown_strict plus its extensions) rather than reasoned from the spec.
-- The scanner exists to predict what pandoc will treat as code, so a
-- disagreement here is a scanner bug by definition.
describe("scanner container nesting", function()
  it("sees a fenced block inside a blockquote", function()
    local lines = scanner.scan('> ```python\n> {"k": 1}\n> ```\n\nafter\n')
    assert.is_true(lines[1].in_code)
    assert.equals("open", lines[1].fence)
    assert.equals("python", lines[1].info)
    assert.is_true(lines[2].in_code)
    assert.equals("close", lines[3].fence)
    assert.is_false(lines[5].in_code)
  end)

  it("sees an indented block inside a blockquote", function()
    -- A bare ">" is the blank line that opens the indented block.
    local lines = scanner.scan("> para\n>\n>     sample\n\nafter\n")
    assert.is_true(lines[3].in_code)
    assert.is_false(lines[5].in_code)
  end)

  it("sees a fence nested two blockquotes deep", function()
    local lines = scanner.scan("> > ```\n> > sample\n> > ```\n")
    assert.is_true(lines[2].in_code)
  end)

  it("handles a blockquote marker with no space after it", function()
    local lines = scanner.scan(">```\n>sample\n>```\n")
    assert.is_true(lines[2].in_code)
  end)

  it("does not treat a four-space line under a numbered item as code", function()
    -- "1. " puts content at column 3, so code needs column 7. Four spaces is
    -- a lazy paragraph continuation -- and an attribute an author indents by
    -- habit there must still be converted, not skipped as code.
    local lines = scanner.scan("1. item one\n\n    {ix: \"term\"}\n\n2. item two\n")
    assert.is_false(lines[3].in_code)
  end)

  it("treats an eight-space line under a numbered item as code", function()
    local lines = scanner.scan("1. item one\n\n        sample\n\n2. item two\n")
    assert.is_true(lines[3].in_code)
  end)

  it("measures a bullet item's content column too", function()
    local indented = scanner.scan("- item\n\n      sample\n\n- two\n")
    assert.is_true(indented[3].in_code)

    local para = scanner.scan("- item\n\n  {ix: \"term\"}\n\n- two\n")
    assert.is_false(para[3].in_code)
  end)

  it("keeps a fence aligned to a wide list marker a fence, info string and all", function()
    -- "10. " puts content at column 4. Measuring from column 0 would reject
    -- the delimiter as over-indented and silently drop the language.
    local lines = scanner.scan("10. item ten\n\n    ```python\n    sample\n    ```\n")
    assert.equals("open", lines[3].fence)
    assert.equals("python", lines[3].info)
    assert.is_true(lines[4].in_code)
  end)

  it("handles a fence inside a list inside a blockquote", function()
    local lines = scanner.scan("> 1. item\n>\n>    ```\n>    sample\n>    ```\n")
    assert.is_true(lines[4].in_code)
  end)

  it("resumes plain measurement after a blockquote ends", function()
    local lines = scanner.scan("> quoted\n\n    sample\n")
    assert.is_true(lines[3].in_code)
  end)
end)

describe("scanner container-state isolation", function()
  it("does not let a closed quoted fence clear a later top-level list", function()
    -- The fence's blockquote depth outlived the fence, so a later top-level
    -- line looked like it had left a container and cleared the list's content
    -- column -- turning that item's lazy continuation into code.
    local lines = scanner.scan("> ```\n> x\n> ```\n\n1. item\n\n    {ix: \"term\"}\n")
    assert.is_false(lines[7].in_code)
  end)

  it("measures a list marker whose gap is a tab", function()
    -- pandoc reads "1.<tab>item" as a list, so its content column is 4 and a
    -- five-column line is a continuation, not code. Counting bytes instead of
    -- expanding the tab put the content column at 0 and called it code.
    local continuation = scanner.scan("1.\titem\n\n\t {ix: \"term\"}\n")
    assert.is_false(continuation[3].in_code)

    local code = scanner.scan("1.\titem\n\n\t\t sample\n")
    assert.is_true(code[3].in_code)
  end)

  it("measures a bullet marker whose gap is a tab", function()
    local lines = scanner.scan("-\titem\n\n\t {ix: \"term\"}\n")
    assert.is_false(lines[3].in_code)
  end)

  it("replays list context correctly when an unclosed fence reverts", function()
    -- The stray ``` is not a fence, so "1. item" is a lazy continuation of
    -- the paragraph it starts rather than a list -- no content column is
    -- opened, and the four-space line after the blank is ordinary top-level
    -- indented code. Verified against pandoc, which emits exactly that Para
    -- plus CodeBlock pair.
    local lines = scanner.scan("```\n1. item\n\n    {ix: \"term\"}\n")
    assert.is_false(lines[1].in_code)
    assert.is_false(lines[2].in_code)
    assert.is_true(lines[4].in_code)
  end)
end)

describe("scanner tilde fences", function()
  -- The Markua spec supports tildes as a fence delimiter: "You can also insert
  -- an inline resource using three or more tildes (`~`) as the delimiter,
  -- instead of the more typical backticks". pandoc only honours that with the
  -- `fenced_code_blocks` extension, which the reader's TARGET_FORMAT must
  -- therefore carry -- without it a legitimate ~~~ block parses as prose with
  -- Subscript artifacts, and every writer renders it wrong.
  it("treats a tilde fence as code, like a backtick fence", function()
    local lines = scanner.scan("~~~python\nsample\n~~~\n\nafter\n")
    assert.equals("open", lines[1].fence)
    assert.equals("python", lines[1].info)
    assert.is_true(lines[2].in_code)
    assert.equals("close", lines[3].fence)
    assert.is_false(lines[5].in_code)
  end)

  it("recognises a tilde fence inside a list item and a blockquote", function()
    local list = scanner.scan("- item\n\n  ~~~lua\n  sample\n  ~~~\n")
    assert.is_true(list[4].in_code)

    local quoted = scanner.scan("> ~~~\n> sample\n> ~~~\n")
    assert.is_true(quoted[2].in_code)
  end)

  it("does not let a backtick delimiter close a tilde fence", function()
    local lines = scanner.scan("~~~text\n```\nstill code\n~~~\nout\n")
    assert.is_true(lines[2].in_code)
    assert.is_true(lines[3].in_code)
    assert.equals("close", lines[4].fence)
    assert.is_false(lines[5].in_code)
  end)
end)
