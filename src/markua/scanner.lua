--- Split a document into line records, tracking fenced-code state.
--
-- Every other module consumes this instead of raw text. Content inside a
-- fence is never Markua: manuscripts contain JSON blocks whose lines start
-- with '{', which a naive attribute-list match would corrupt.
local M = {}

local TAB_STOP = 4

-- Column width of a line's leading whitespace, expanding tabs to the next
-- 4-column stop (CommonMark's rule, verified against pandoc 3.10.1). A
-- character count treats a tab as one column, which keeps a tab-indented
-- "\t```" a fence and a tab-indented "\t{timeout: 30}" prose -- both wrong:
-- pandoc parses the first as an indented code block and the second as a
-- CodeBlock. Both the fence-recognition and indented-code checks below route
-- through this same measure so they agree with each other and with pandoc.
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

function M.scan(text)
  text = normalize_newlines(text)

  local lines = {}
  local open_marker = nil
  local indented = false      -- inside a four-column indented code block
  local prev_blank = true     -- start of document counts as a blank
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
    local blank = is_blank(line)
    local marker, info = fence_parts(line)
    local record = { text = line, number = number, in_code = open_marker ~= nil }

    if open_marker then
      -- Inside a fence: only a matching closing marker matters.
      if marker and marker:sub(1, 1) == open_marker:sub(1, 1)
         and #marker >= #open_marker and info == "" then
        record.fence = "close"
        open_marker = nil
      end
    elseif marker then
      open_marker = marker
      indented = false
      record.in_code = true
      record.fence = "open"
      record.info = info
    else
      -- An indented code block starts on a four-column indent after a blank
      -- line, and runs until a non-blank line dedents. Without this, a code
      -- sample such as "    {timeout: 30}" reads as a Markua attribute list
      -- and gets rewritten -- the same corruption fences protect against.
      if indented then
        if blank then
          record.in_code = true          -- blank lines do not end the block
        elseif indent_columns(line) >= 4 then
          record.in_code = true
        else
          indented = false
        end
      elseif prev_blank and not blank and indent_columns(line) >= 4 then
        indented = true
        record.in_code = true
      end
    end

    prev_blank = blank

    lines[#lines + 1] = record
  end

  return lines
end

return M
