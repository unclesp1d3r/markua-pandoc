--- Block-level Markua to pandoc-markdown rewrites.
--
-- U1 ships the pass skeleton: fence passthrough, and the pending
-- attribute-list lifecycle every later block construct binds into. `B>` and
-- fenced `{blurb}` handling (U2), the C/D/E/I/Q/T/W/X> sugar prefixes (U3),
-- `A>` and fenced `{aside}` handling (U4), and the bare-word directive table
-- (U5) each add a branch to the attribute-line and prefix dispatch below,
-- ahead of the generic "unclaimed attribute list" fallback this unit builds.
-- None of those branches exist yet: a bare word like "blurb" or "pagebreak"
-- falls through to that fallback here, exactly like any other list this pass
-- does not recognize.
local attributes = require("src.markua.attributes")
local errors = require("src.markua.errors")

local M = {}

-- An attribute list holding only index keys belongs to inline.transform,
-- which runs after this pass. Re-emit it untouched rather than treating it
-- as a pending block attribute, or a standalone {ix: "term"} line would
-- surface as literal text in the finished book.
local function is_index_only(parsed, cfg)
  if parsed.id or #parsed.classes > 0 or #parsed.bare > 0 then
    return false
  end
  local count = 0
  for key in pairs(parsed.keyvals) do
    local known = false
    for _, index_key in ipairs(cfg.index_keys) do
      if key == index_key then
        known = true
      end
    end
    if not known then
      return false
    end
    count = count + 1
  end
  return count > 0
end

function M.transform(lines, cfg, file)
  local out = {}
  local pending = nil        -- attribute list awaiting its element
  local pending_line = nil
  local pending_text = nil   -- the raw line, for verbatim re-emission
  local i = 1

  local function emit(s)
    out[#out + 1] = s
  end

  -- A body line that is exactly ":::" or "$$" would close a fence this pass
  -- opened elsewhere in the document, desynchronizing every block after it.
  -- pandoc's own markdown writer backslash-escapes such a line rather than
  -- erroring (a ":::" paragraph inside a div is written "\:::" and reads
  -- back identically), so every non-fence, non-attribute line this pass
  -- emits goes through here -- not only the callout bodies U2 and U4 add,
  -- because a plain paragraph elsewhere in the document can collide with a
  -- delimiter this pass generates just as easily.
  local function emit_body(s)
    if s:match("^%s*:::+%s*$") or s:match("^%s*%$%$%s*$") then
      emit((s:gsub("^(%s*)", "%1\\", 1)))
    else
      emit(s)
    end
  end

  -- Nothing may see a pending attribute list and quietly forget it. Every
  -- exit from the pending state goes through here, so an unclaimed list
  -- aborts with its own line number instead of leaking braces into the book
  -- or vanishing (R21). Called as the FIRST action of any branch that does
  -- not consume the pending list itself -- the branches that do consume it
  -- (headings here, plus B>, the sugar prefixes, and A> once U2-U4 add them)
  -- are untouched by this rule.
  local function reject_pending(reason)
    if not pending then
      return
    end
    local text = pending_text
    errors.report(cfg, file, pending_line,
      (reason or "attribute list applies to nothing") .. ": " .. text)
    -- Only reached when cfg.strict is false. Re-emit verbatim, at the
    -- position of the line that disqualified it: leniency preserves the
    -- author's text and never reorders or deletes it (R22). Resolving this
    -- in the same loop iteration as the disqualifying line -- rather than
    -- tracking and rewriting an output index -- is what keeps that true
    -- without bookkeeping: the append lands here, before whatever that line
    -- goes on to emit.
    emit(text)
    pending, pending_line, pending_text = nil, nil, nil
  end

  while i <= #lines do
    local rec = lines[i]
    local text = rec.text

    if rec.in_code then
      emit(text)
      i = i + 1

    elseif attributes.is_attribute_line(text) then
      local parsed = attributes.parse(text, file, rec.number)

      if is_index_only(parsed, cfg) then
        reject_pending()
        emit(text)                     -- verbatim; inline.transform owns it
        i = i + 1
      else
        -- U2 inserts a branch here for the bare word "blurb", U4 for
        -- "aside", U5 for the full directive table. Until they land, every
        -- other attribute list -- including a bare-word directive line --
        -- falls through to this generic swap, which is what keeps it from
        -- silently binding to whatever line happens to follow it.
        reject_pending()               -- a new list may not shadow an unused one
        pending, pending_line, pending_text = parsed, rec.number, text
        i = i + 1
      end

    else
      if pending and text:match("^#+%s") then
        -- to_pandoc_attr renders id, classes and keyvals only. An
        -- unrecognized bare word would vanish into an empty "{}" on the
        -- heading, which is exactly the silent pass-through the hard-error
        -- constraint forbids.
        if #pending.bare > 0 then
          reject_pending("unrecognized attribute `" .. pending.bare[1] .. "`")
          emit(text)
        else
          emit(text .. " " .. attributes.to_pandoc_attr(pending, file, pending_line))
          pending, pending_line, pending_text = nil, nil, nil
        end
      else
        -- Covers plain prose, blank lines, and B>/A> lines before U2-U4 add
        -- their own branches above this one. A blank line no longer holds a
        -- pending list across it (KTD6): spec.txt:6647 requires the
        -- attribute list to directly precede its element with no blank line
        -- between them, so a blank goes through the same rejection as any
        -- other unclaimed case, not a special case that survives it.
        reject_pending("attribute list precedes no element it can apply to")
        emit_body(text)
      end
      i = i + 1
    end
  end

  -- A list in the final position still applies to nothing. This is live, not
  -- a safety net: scanner.scan appends a trailing blank record only when the
  -- source ends in a newline, so a file whose last line is the attribute list
  -- and carries no final newline reaches here with `pending` still set. That
  -- is the one path satisfying R21's "end of input" case, and deleting it as
  -- unreachable would silently drop the error.
  reject_pending("attribute list at end of input")

  return out
end

return M
