--- Parse Markua attribute lists: {key: value, "quoted", #id, .class}.
--
-- Pure syntax. This module has no opinion about what any attribute means;
-- blocks.lua and resources.lua interpret them. It never unescapes a source
-- value -- `\"` in `parse`'s input stays `\"` verbatim in the parsed value.
-- Consumers own rejecting bare words they do not recognize (e.g. an
-- unparseable key, or a construct-specific word like "blurb"); this module
-- only tokenizes.
--
-- `parse` and `to_pandoc_attr` are NOT inverses, and must not be chained
-- directly on a value carrying a source escape. `parse` yields Markua-level
-- text (`\"` still escaped); `to_pandoc_attr` expects semantic text and
-- escapes what it is given, so feeding one straight into the other turns
-- `She said \"hi\"` into a value pandoc reads back with literal backslashes.
-- Whichever consumer first needs the round trip owns the unescape step
-- between them; where that belongs is a Markua-spec question this module
-- deliberately does not answer.
local errors = require("src.markua.errors")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_attribute_line(text)
  local t = trim(text)
  return t:sub(1, 1) == "{" and t:sub(-1) == "}" and #t >= 2
end

-- Count the run of consecutive backslashes immediately before position i in
-- body (1-indexed, exclusive of i itself). Used to decide whether the `"` at
-- i is escaped: an odd count means the backslash run ends in an unescaped
-- backslash that swallows this quote, so it does not toggle quote state.
local function backslash_run_length(body, i)
  local count = 0
  local j = i - 1
  while j >= 1 and body:sub(j, j) == "\\" do
    count = count + 1
    j = j - 1
  end
  return count
end

-- Split on commas that are not inside double quotes.
--
-- A `"` toggles quote state only when it is not escaped -- i.e. when it is
-- preceded by an even number (including zero) of consecutive backslashes.
-- Without this, `{title: "She said \"hi, there\""}` desyncs on the first
-- escaped `"`: the naive every-quote-toggles version treats it as a closing
-- quote, so the comma after it splits the field, truncating the value to
-- `"She said \"hi` and inventing a spurious bare word `there\""`. This is
-- tokenizing only -- the backslash stays in the field text verbatim; `parse`
-- does not unescape it.
--
-- A quote that never closes does not delimit anything, so quote state is
-- disabled for the whole body rather than left stuck on. Without this,
-- `{title: "abc, class: tip}` swallows the following field: the comma stops
-- separating and `class: tip` disappears into the title with no error. This
-- follows pandoc, which recovers the same way -- `{#h title="abc class=tip}`
-- yields the value `"abc` AND still applies the class `tip`, keeping the
-- stray quote literally rather than rejecting the document. Erroring instead
-- would refuse input that parses correctly today, such as `{title: 5" pipe}`.
local function has_balanced_quotes(body)
  local open = false
  for i = 1, #body do
    if body:sub(i, i) == '"' and backslash_run_length(body, i) % 2 == 0 then
      open = not open
    end
  end
  return not open
end

local function split_fields(body)
  local quotes_delimit = has_balanced_quotes(body)
  local fields, buf, in_quote = {}, {}, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '"' and quotes_delimit and backslash_run_length(body, i) % 2 == 0 then
      in_quote = not in_quote
      buf[#buf + 1] = c
    elseif c == "," and not in_quote then
      fields[#fields + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
  end
  fields[#fields + 1] = table.concat(buf)
  return fields
end

local function unquote(v)
  local inner = v:match('^"(.*)"$')
  return inner or v
end

--- Parse an attribute list. `sink` is optional and only receives duplicate-key
--- warnings; it is the seam a later caller uses to collect them into the
--- warning list the Markua spec asks a Processor to keep, rather than writing
--- each one straight to stderr.
function M.parse(text, file, line, sink)
  local t = trim(text)
  local body = t:match("^{(.*)}$")
  if not body then
    errors.raise(file, line, "not an attribute list: " .. t)
  end

  -- Carry the source position on the table itself. `to_pandoc_attr` raises
  -- for a name pandoc cannot read back, but it is called later and elsewhere
  -- than `parse`, so relying on every consumer to rethread file/line across
  -- that gap loses the position exactly where the error needs it -- the two
  -- draft consumers in docs/plan.md (Tasks 5 and 7) already call
  -- `to_pandoc_attr(pending)` with no position, which would report
  -- `nil:nil: id "..." cannot be represented` to an author.
  local parsed = { id = nil, classes = {}, keyvals = {}, bare = {}, file = file, line = line }
  local seen_keys = {}

  for _, field in ipairs(split_fields(body)) do
    local f = trim(field)
    if f ~= "" then
      local key, value = f:match("^([%w%-_]+)%s*:%s*(.*)$")
      if key then
        value = unquote(trim(value))
        if seen_keys[key] then
          -- Markua spec, "Attribute Keys": "If a key is duplicated in an
          -- attribute list, the first key value is used and subsequent ones
          -- are ignored. A Markua Processor should add a warning in its list
          -- of warnings, which are *not* output in the output itself." This
          -- is a warning, not an error -- the document still has a defined
          -- meaning -- so the later value is dropped and the author is told.
          errors.warn(file, line, string.format("duplicate attribute key %q; first value kept", key), sink)
        elseif key == "class" then
          -- `class` is an ordinary attribute key, so the duplicate rule above
          -- governs it too: a repeated class: does not accumulate. The
          -- classes list exists for the `.name` shortcut, which is a
          -- different syntax.
          -- pandoc splits a class value on whitespace
          -- ("class" -> cs ++ T.words val in keyValAttr), so `{class: "tip
          -- wide"}` is two classes rather than one unrepresentable name.
          seen_keys[key] = true
          for word in value:gmatch("%S+") do
            parsed.classes[#parsed.classes + 1] = word
          end
        else
          seen_keys[key] = true
          parsed.keyvals[key] = value
        end
      elseif f:sub(1, 1) == "#" then
        -- Same first-wins rule; the spec asks for an error in the log rather
        -- than a warning for a duplicate id, but the value still resolves, so
        -- this reports without aborting.
        if parsed.id ~= nil then
          errors.warn(file, line, "duplicate id; first value kept", sink)
        else
          parsed.id = f:sub(2)
        end
      elseif f:sub(1, 1) == "." then
        parsed.classes[#parsed.classes + 1] = f:sub(2)
      else
        -- Neither key: value, #id, nor .class. This is not necessarily an
        -- error: `blurb`, `frontmatter`, and `/blurb` are all legitimate
        -- bare words whose meaning belongs to a later module (KTD5). A
        -- consumer that does not recognize this word names it in the hard
        -- error AGENTS.md requires; attributes.lua stays pure syntax and
        -- does not guess.
        parsed.bare[#parsed.bare + 1] = f
      end
    end
  end

  return parsed
end

-- Render a value for pandoc's attribute syntax, choosing the quote character
-- the way pandoc's keyValAttr can actually read back:
--
--   val <- enclosed (char '"')  (char '"')  litChar
--      <|> enclosed (char '\'') (char '\'') litChar
--      <|> ...
--
-- The reader's target format is markdown_strict plus extensions, which leaves
-- all_symbols_escapable OFF, so only original Markdown's escapable set works.
-- A backslash is in that set; a double quote is not. Verified against pandoc
-- 3.10.1 under that exact format: {title="He said \"hi\""} does not parse --
-- pandoc abandons the whole construct and renders the ::: delimiters as
-- literal paragraph text -- while {title='He said "hi"'} parses to the value
-- `He said "hi"`. Escaping the quote is what -f markdown accepts; measuring
-- the format actually handed to pandoc.read is what caught the difference.
--
-- So the quote character carries the value instead of an escape: single
-- quotes when it contains a double quote, double quotes otherwise. A value
-- containing both is unrepresentable here and is a hard error rather than
-- silent corruption.
local function escape_backslashes(v)
  return (v:gsub("\\", "\\\\"))
end

local function render_value(v, file, line)
  local has_double, has_single = v:find('"', 1, true), v:find("'", 1, true)
  if has_double and has_single then
    errors.raise(file, line,
      "attribute value carries both a single and a double quote, which pandoc's attribute syntax cannot express: " .. v)
  end
  local body = escape_backslashes(v)
  if has_double then
    return "'" .. body .. "'"
  end
  return '"' .. body .. '"'
end

-- An id or class has no escape syntax in pandoc's attribute block -- unlike a
-- value, which quotes and backslashes can always carry. The accepted shapes
-- are pandoc's own, from Readers/Markdown.hs:
--
--   identifierAttr = char '#' >> many1 (alphaNum <|> oneOf "-_:.")
--   identifier     = letter >> many (alphaNum <|> oneOf "-_:.")   -- class
--
-- So an id may start with a digit but a class may not, and neither may contain
-- anything else. Emitting a name outside that grammar does not merely lose the
-- name: pandoc rejects the *entire* attribute block and renders it as literal
-- text, so `{#a&b .3things}` leaks braces into the prose and drops every other
-- attribute with it -- the "never pass through as literal braces into the
-- output" failure AGENTS.md forbids. Verified against pandoc 3.10.1: `{#a&b}`,
-- `{#a%b}` and `{.3things}` all come back as literal Str, while `{#3things}`,
-- `{#a:b}`, `{#a.b}` and `{#caf\233}` parse.
--
-- Bytes >= 0x80 are accepted as name characters. pandoc's alphaNum is Unicode
-- aware, so `café` and CJK ids are legal there; matching that exactly would
-- mean a Unicode character-class table in pure Lua. Accepting the high range
-- errs toward passing real author text through rather than falsely rejecting
-- it, at the cost of not catching an exotic non-alphanumeric symbol.
local ID_PATTERN = "^[%w%-_:.\128-\255]+$"
local CLASS_PATTERN = "^[%a\128-\255][%w%-_:.\128-\255]*$"

local function check_name(kind, name, file, line)
  local pattern = kind == "class" and CLASS_PATTERN or ID_PATTERN
  if not name:match(pattern) then
    errors.raise(file, line, string.format("%s %q cannot be represented in a pandoc attribute", kind, name))
  end
end

--- Render a parsed attribute list as a pandoc attribute block.
--- `file` and `line` are optional and only position the error raised when an
--- id or class cannot be represented.
function M.to_pandoc_attr(parsed, file, line)
  -- Fall back to the position parse recorded, so a caller that omits these
  -- still produces an error naming the author's file and line.
  file = file or parsed.file
  line = line or parsed.line
  local parts = {}
  if parsed.id then
    check_name("id", parsed.id, file, line)
    parts[#parts + 1] = "#" .. parsed.id
  end
  for _, c in ipairs(parsed.classes) do
    check_name("class", c, file, line)
    parts[#parts + 1] = "." .. c
  end
  -- Sorted keys are the determinism mechanism for R18: iterating pairs()
  -- directly would order keyvals by Lua's internal hash order, which is not
  -- guaranteed stable across runs.
  local keys = {}
  for k in pairs(parsed.keyvals) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s=%s", k, render_value(parsed.keyvals[k], file, line))
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

return M
