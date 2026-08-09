--- Parse Markua attribute lists: {key: value, "quoted", #id, .class}.
--
-- Pure syntax. This module has no opinion about what any attribute means;
-- blocks.lua and resources.lua interpret them. It never unescapes a source
-- value -- `\"` in `parse`'s input stays `\"` verbatim in the parsed value.
-- Consumers own rejecting bare words they do not recognize (e.g. an
-- unparseable key, or a construct-specific word like "blurb"); this module
-- only tokenizes.
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
local function split_fields(body)
  local fields, buf, in_quote = {}, {}, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == '"' and backslash_run_length(body, i) % 2 == 0 then
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

function M.parse(text, file, line)
  local t = trim(text)
  local body = t:match("^{(.*)}$")
  if not body then
    errors.raise(file, line, "not an attribute list: " .. t)
  end

  local parsed = { id = nil, classes = {}, keyvals = {}, bare = {} }

  for _, field in ipairs(split_fields(body)) do
    local f = trim(field)
    if f ~= "" then
      local key, value = f:match("^([%w%-_]+)%s*:%s*(.*)$")
      if key then
        value = unquote(trim(value))
        if key == "class" then
          parsed.classes[#parsed.classes + 1] = value
        else
          parsed.keyvals[key] = value
        end
      elseif f:sub(1, 1) == "#" then
        parsed.id = f:sub(2)
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

-- Backslash-escape a value for pandoc's attribute syntax. `\` is escaped
-- first, then `"`. Escaping `"` first would double-escape the backslashes
-- that pass introduces: e.g. a literal `"` would become `\"`, and then the
-- `\` pass would turn that into `\\"` instead of the intended `\"`. Verified
-- against pandoc 3.10.1 (KTD4): title="He said \"hi\"" parses back to the
-- value `He said "hi"`, while an unescaped `"` does not degrade gracefully --
-- pandoc abandons the whole construct and renders the `:::` delimiters as
-- literal paragraph text.
local function escape_value(v)
  v = v:gsub("\\", "\\\\")
  v = v:gsub('"', '\\"')
  return v
end

function M.to_pandoc_attr(parsed)
  local parts = {}
  if parsed.id then
    parts[#parts + 1] = "#" .. parsed.id
  end
  for _, c in ipairs(parsed.classes) do
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
    parts[#parts + 1] = string.format('%s="%s"', k, escape_value(parsed.keyvals[k]))
  end
  return "{" .. table.concat(parts, " ") .. "}"
end

return M
