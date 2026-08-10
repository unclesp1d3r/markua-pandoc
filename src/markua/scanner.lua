--- Split a document into line records, tracking fenced-code state.
--
-- Every other module consumes this instead of raw text. Content inside a
-- fence is never Markua: manuscripts contain JSON blocks whose lines start
-- with '{', which a naive attribute-list match would corrupt.
local M = {}

local TAB_STOP = 4

-- Column width of a line's leading whitespace, expanding tabs to the next
-- 4-column stop (CommonMark's rule, verified against pandoc 3.10.1). Matching
-- only spaces scores a tab as zero, which keeps a tab-indented "\t```" a fence
-- and a tab-indented "\t{timeout: 30}" prose -- both wrong: pandoc parses the
-- first as an indented code block and the second as a CodeBlock. Both the
-- fence-recognition and indented-code checks below route through this same
-- measure so they agree with each other and with pandoc.
local function indent_columns(line)
  local column = 0
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == " " then
      column = column + 1
    elseif ch == "\t" then
      column = column - (column % TAB_STOP) + TAB_STOP
    else
      break
    end
  end
  return column
end

-- The two fence markers, as a table rather than chained matches: Lua patterns
-- have no alternation, so every multi-alternative match in this reader is an
-- explicit loop over a table of patterns.
local FENCE_PATTERNS = { "^(```+)(.*)$", "^(~~~+)(.*)$" }

-- Returns marker and info string if the line opens or closes a fence.
-- CommonMark allows a fence to be indented up to three columns; at four it is
-- an indented code block instead, which is handled separately below.
local function fence_parts(line)
  if indent_columns(line) > 3 then
    return nil
  end
  local body = line:gsub("^ *", "")
  local marker, info
  for _, pattern in ipairs(FENCE_PATTERNS) do
    marker, info = body:match(pattern)
    if marker then
      break
    end
  end
  if not marker then
    return nil
  end
  return marker, (info or ""):match("^%s*(.-)%s*$")
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- Normalize CRLF and lone-CR line endings to LF before splitting, so no
-- downstream module -- most of which anchor Lua patterns on "$" or "\n" --
-- has to special-case a carriage return. CRLF must be substituted first: a
-- lone-CR pass run first would collapse "\r\n" into "\n\n", inventing a
-- blank line the source never had.
local function normalize_newlines(text)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("\r", "\n")
  return text
end

-- Strip a blockquote prefix, returning its depth and the content after it.
-- CommonMark allows up to three spaces before each ">" and swallows one
-- optional space after it. Without this the scanner is blind to every fence
-- and indented block inside a quote: pandoc parses "> ```python" as a real
-- CodeBlock, while a raw-line scanner sees prose and lets a later transform
-- rewrite the sample -- the corruption this module exists to prevent, just
-- one container deeper.
local function strip_blockquote(line)
  local depth, rest, column = 0, line, 0
  while true do
    local indent, tail = rest:match("^( ? ? ?)>(.*)$")
    if not indent then
      return depth, rest
    end
    column = column + #indent + 1          -- past the ">" itself
    -- The marker swallows one optional space. A tab is not one space: it
    -- expands to the next 4-column stop, the marker takes one column of that
    -- expansion, and the remainder is real indentation. Eating the whole tab
    -- byte instead loses those columns, so "> " + tab + two spaces measured 2
    -- columns here while pandoc measured 4 and made it a CodeBlock.
    local first = tail:sub(1, 1)
    if first == "\t" then
      local width = TAB_STOP - (column % TAB_STOP)
      rest = (" "):rep(width - 1) .. tail:sub(2)
    elseif first == " " then
      rest = tail:sub(2)
      column = column + 1
    else
      rest = tail
    end
    depth = depth + 1
  end
end

-- Display column of the byte at `stop`, expanding tabs to the same 4-column
-- stops as indent_columns. A list marker's gap may be a tab, so a byte count
-- is not a column count.
local function column_at(text, stop)
  local column = 0
  for i = 1, stop - 1 do
    if text:sub(i, i) == "\t" then
      column = column - (column % TAB_STOP) + TAB_STOP
    else
      column = column + 1
    end
  end
  return column
end

-- Content column of a list item's body, or nil when the line starts no item.
-- A bullet or ordered marker shifts where that item's content begins, and
-- CommonMark measures its nested code from there -- so "1. item" followed by
-- a four-space line is a lazy paragraph continuation (content column 3, and
-- 4 < 3 + 4), not code. Measuring from column 0 instead made the scanner
-- report that line as code and skip a Markua attribute an author indented by
-- habit under a numbered step. The gap after the marker may be a tab, which
-- pandoc still reads as a list, so both the indent and the gap expand through
-- the tab-stop rule rather than counting bytes.
local LIST_MARKERS = { "^([ \t]*)([-+*])([ \t]+)", "^([ \t]*)(%d+[.)])([ \t]+)" }

local function list_content_column(rest)
  for _, pattern in ipairs(LIST_MARKERS) do
    local indent, marker, gap = rest:match(pattern)
    if indent then
      return column_at(rest, #indent + #marker + #gap + 1)
    end
  end
  return nil
end

-- Re-run the indented-code rule over a range whose fence turned out never to
-- close. Same rules as the main loop, so a reverted range is classified
-- exactly as if the stray fence delimiter had never been treated as one.
local function reclassify(records, facts, from, to)
  local indented = false
  local prev_blank = from > 1 and facts[from - 1].blank or true
  for i = from, to do
    local fact = facts[i]
    local in_code = false
    if indented then
      if fact.blank or fact.relative >= 4 then
        in_code = true
      else
        indented = false
      end
    elseif prev_blank and not fact.blank and fact.relative >= 4 then
      indented, in_code = true, true
    end
    records[i].in_code = in_code
    records[i].fence = nil
    records[i].info = nil
    prev_blank = fact.blank
  end
end

function M.scan(text)
  text = normalize_newlines(text)

  local records, facts = {}, {}
  local open_marker, open_depth, open_index = nil, 0, nil
  local indented = false      -- inside a four-column indented code block
  local prev_blank = true     -- start of document counts as a blank
  -- A stack, not a single column: dedenting out of a nested item returns to
  -- the *enclosing* item's content column, not to top level. Resetting to 0
  -- made "10. outer" / "    - nested" / "    {ix: ...}" read as code, where
  -- pandoc keeps that last line a lazy continuation of the outer item.
  local list_stack = {}       -- { { column = n, depth = n }, ... }, innermost last
  local number = 0

  -- The "text .. \n" split (and the empty trailing record it produces for
  -- newline-terminated input) is load-bearing, not an off-by-one: it is what
  -- makes join(records, "\n") reproduce the input exactly (R10). Every
  -- transform stage scans and rejoins, so an exact round trip is what stops
  -- trailing newlines from drifting across stages. Do not trim it. Its one
  -- consequence: that trailing record's `number` counts one past the
  -- document's last real line, so a caller reporting an error position from
  -- `record.number` must not assume every record names a line an author can
  -- open.
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1

    -- Everything below measures the line's *content*, not its raw text: the
    -- blockquote prefix is stripped first, then indentation is taken relative
    -- to the enclosing list item's content column. A fence or indented block
    -- means the same thing at any container depth, so resolving the prefix
    -- once here keeps one rule instead of one per container.
    local depth, rest = strip_blockquote(line)

    -- Blankness is a property of the content, not the raw line: inside a
    -- quote, a bare ">" is the blank line that separates blocks.
    local blank = is_blank(rest)

    -- Leaving a blockquote ends any list opened inside it. That is the list's
    -- own container depth, not the fence's: keying this off open_depth let a
    -- closed quoted fence leave a stale depth behind, which then cleared a
    -- later top-level list and misread its lazy continuation as code. A blank
    -- line ends nothing -- a loose list keeps its item open across one.
    while #list_stack > 0 and list_stack[#list_stack].depth > depth do
      list_stack[#list_stack] = nil
    end
    local list_column = #list_stack > 0 and list_stack[#list_stack].column or 0

    local column = indent_columns(rest)
    if not blank and not open_marker then
      local started = list_content_column(rest)
      if started and column <= list_column + 3 then
        list_stack[#list_stack + 1] = { column = started, depth = depth }
      elseif column < list_column then
        -- Dedent: pop only the items this line has actually left.
        while #list_stack > 0 and column < list_stack[#list_stack].column do
          list_stack[#list_stack] = nil
        end
      end
      list_column = #list_stack > 0 and list_stack[#list_stack].column or 0
    end

    -- A fence sits 0-3 columns past the container's content column; at four
    -- it is indented code instead. Measuring the stripped content means one
    -- fence rule serves every container depth.
    local relative = column - list_column
    local marker, info
    if relative >= 0 and relative <= 3 then
      marker, info = fence_parts((rest:gsub("^%s*", "")))
    end

    local record = { text = line, number = number, in_code = open_marker ~= nil }
    records[number] = record
    facts[number] = { blank = blank, relative = relative }

    if open_marker then
      -- Inside a fence: only a matching closer at the same blockquote depth
      -- counts. A shallower depth means the quote ended first, which under
      -- this reader's target format means the opener was never a fence.
      if depth < open_depth then
        reclassify(records, facts, open_index, number - 1)
        open_marker, open_index, open_depth = nil, nil, 0
        record.in_code = false
      elseif marker and depth == open_depth and marker:sub(1, 1) == open_marker:sub(1, 1)
         and #marker >= #open_marker and info == "" then
        record.fence = "close"
        -- Clear the depth with the fence: a stale open_depth outlives the
        -- construct it described and corrupts unrelated later state.
        open_marker, open_index, open_depth = nil, nil, 0
      end
    elseif marker then
      open_marker, open_depth, open_index = marker, depth, number
      indented = false
      record.in_code = true
      record.fence = "open"
      record.info = info
    else
      -- An indented code block starts four columns past the container's
      -- content column after a blank line, and runs until a non-blank line
      -- dedents. Without this, a code sample such as "    {timeout: 30}"
      -- reads as a Markua attribute list and gets rewritten -- the same
      -- corruption fences protect against.
      if indented then
        if blank then
          record.in_code = true          -- blank lines do not end the block
        elseif relative >= 4 then
          record.in_code = true
        else
          indented = false
        end
      elseif prev_blank and not blank and relative >= 4 then
        indented = true
        record.in_code = true
      end
    end

    prev_blank = blank
  end

  -- A fence still open at the end of the document never closed, so under this
  -- reader's target format (markdown_strict plus extensions, not commonmark)
  -- its delimiter was ordinary text all along. commonmark would run the block
  -- to EOF instead; following the format actually handed to pandoc.read is
  -- what keeps the scanner's answer and pandoc's the same.
  if open_marker then
    reclassify(records, facts, open_index, number)
  end

  return records
end

return M
