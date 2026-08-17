--- Block-level Markua to pandoc-markdown rewrites.
--
-- U1 shipped the pass skeleton: fence passthrough, and the pending
-- attribute-list lifecycle every later block construct binds into. U2 adds
-- `B>` runs and the fenced `{blurb}` … `{/blurb}` form, both producing the
-- same callout div. U4 adds `A>` runs and the fenced `{aside}` … `{/aside}`
-- form -- sharing U2's consume-until-close loop and class-resolution
-- machinery, but a bare aside has no callout-class default the way a bare
-- blurb defaults to `information` (R4 vs R11), and a pending attribute list
-- above an `A>` run is applied rather than rejected the way one above a
-- fenced opener is (KTD7). The C/D/E/I/Q/T/W/X> sugar prefixes (U3) and the
-- bare-word directive table (U5) each add a branch to the attribute-line and
-- prefix dispatch below, ahead of the generic "unclaimed attribute list"
-- fallback U1 builds. Those branches don't exist yet: a bare word like
-- "pagebreak" still falls through to that fallback, exactly like any other
-- list this pass does not recognize.
local attributes = require("src.markua.attributes")
local config = require("src.markua.config")
local errors = require("src.markua.errors")

local M = {}

-- Strip a construct's line prefix and the one space Markua allows after it
-- ("B> text" and "B>text" both mean the same body). Shared by B> now and
-- every sugar prefix U3 adds, so the one-space rule lives in one place.
local function strip_prefix(text, prefix)
  local body = text:sub(#prefix + 1)
  return (body:gsub("^ ", ""))
end

-- Enrich an unknown-class error with the registered spelling when the two
-- differ only by letter case (KTD8). Matching itself stays case-sensitive --
-- this never changes which class resolves, only what an author sees when
-- they typed the wrong case.
local function known_spelling(name, cfg)
  local lower = name:lower()
  for _, c in ipairs(cfg.callout_classes) do
    if c ~= name and c:lower() == lower then
      return c
    end
  end
  return nil
end

-- Scan a class list for the one registered callout class. Per KTD10b, a
-- Markua attribute list is key-value only -- every class, callout or
-- decorative, arrives through one `class:` value that attributes.parse
-- splits on whitespace -- so there is no shorthand to distinguish intent by,
-- and a membership scan is the whole rule. Returns the callout class plus
-- every other class in source order (R8, the decorative-class case); reports
-- when none of the classes is registered (R6).
--
-- Reporting rather than raising is deliberate. AGENTS.md makes an unknown
-- construct a hard error that `--lenient` downgrades to a warning, and an
-- unregistered class is exactly that; the reference this pass started from
-- used an unconditional raise, which left `--lenient` able to recover from an
-- unclaimed attribute list but not from a bad class. That asymmetry defeats
-- leniency for its documented job -- triaging a manuscript whose classes do
-- not match this book's list, which is the common case, since real Leanpub
-- builds reject `note` and books narrow the set further. Under leniency the
-- author's own first class becomes the head, so their text survives into the
-- output the same way reject_pending preserves an unclaimed list.
local function resolve_callout_class(classes, cfg, file, line)
  for idx, c in ipairs(classes) do
    if config.is_callout_class(cfg, c) then
      local decoratives = {}
      for j, other in ipairs(classes) do
        if j ~= idx then
          decoratives[#decoratives + 1] = other
        end
      end
      return c, decoratives
    end
  end
  local hint = ""
  for _, c in ipairs(classes) do
    local known = known_spelling(c, cfg)
    if known then
      hint = " (classes are case-sensitive; did you mean '" .. known .. "'?)"
      break
    end
  end
  errors.report(cfg, file, line,
    "unknown callout class '" .. table.concat(classes, "', '") .. "'" .. hint)
  local head = classes[1]
  local decoratives = {}
  for j = 2, #classes do
    decoratives[#decoratives + 1] = classes[j]
  end
  return head, decoratives
end

-- A B> run or fenced opener with no explicit class defaults to `information`
-- (R4); an empty class list never reaches resolve_callout_class, so the
-- default never has an unresolvable line/file to report against.
local function callout_classes(classes, cfg, file, line)
  if #classes == 0 then
    return "information", {}
  end
  return resolve_callout_class(classes, cfg, file, line)
end

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

  -- The callout class MUST be the head of the class list, and `.blurb` /
  -- `.aside` MUST be last: pandoc's DocBook writer matches only the first
  -- class (`(l:_) | l `elem` admonitions`), so "{.blurb .tip}" degrades to a
  -- bare <para> with no error anywhere, while "{.tip .blurb}" becomes a real
  -- <tip>. Decorative classes ride between the two, in the source order the
  -- author wrote them (R8) -- the reference this pass started from resolved
  -- one callout class and silently dropped every other one, which this
  -- fixes by taking the whole list instead of a single resolved name.
  local function open_div(head, decoratives, marker)
    local parts = { "." .. head }
    for _, c in ipairs(decoratives) do
      parts[#parts + 1] = "." .. c
    end
    parts[#parts + 1] = "." .. marker
    emit("::: {" .. table.concat(parts, " ") .. "}")
  end

  -- Unlike a blurb, a bare aside has no callout-class default: `A>` alone
  -- and an empty `{aside}` both emit exactly `::: {.aside}` (R11, R12) --
  -- Task 11's downstream filter and issue #6's table expect that bare
  -- shape, so there is no `information` fallback to reach for here the way
  -- callout_classes gives blurbs. A non-empty class list resolves through
  -- the same resolve_callout_class a blurb's does, so a bad class raises
  -- identically in both constructs (KTD7).
  local function open_aside(classes, line)
    if not classes or #classes == 0 then
      emit("::: {.aside}")
    else
      local head, decoratives = resolve_callout_class(classes, cfg, file, line)
      open_div(head, decoratives, "aside")
    end
  end

  -- Consume lines up to (not including) the fenced closer for `marker`,
  -- shared by the {blurb} and {aside} fenced forms (R3, R12): a code sample
  -- inside the body can legitimately contain the closing text, so only a
  -- matching line OUTSIDE a fence terminates the construct (R10), and the
  -- closer word is taken from `marker` rather than hardcoded so this one
  -- loop can never let a {blurb} div wait on {/aside} or vice versa.
  local function consume_until_close(marker, opened_at)
    local closer = "^%s*{/" .. marker .. "}%s*$"
    i = i + 1
    while i <= #lines and not (not lines[i].in_code and lines[i].text:match(closer)) do
      emit_body(lines[i].text)
      i = i + 1
    end
    if i > #lines then
      -- R9/R12: a block running silently to end of input is exactly what
      -- this guards against. Position the error at the opener, not here,
      -- since "here" is past the last line an author can point to.
      errors.raise(file, opened_at, "unclosed {" .. marker .. "} opened here")
    end
    emit(":::")
    i = i + 1
  end

  -- Nothing may see a pending attribute list and quietly forget it. Every
  -- exit from the pending state goes through here, so an unclaimed list
  -- aborts with its own line number instead of leaking braces into the book
  -- or vanishing (R21). Called as the FIRST action of any branch that does
  -- not consume the pending list itself -- the branches that do consume it
  -- (headings, B> runs, and A> runs here, plus the sugar prefixes once U3
  -- adds them) are untouched by this rule.
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
      elseif #parsed.bare == 1 and parsed.bare[1] == "blurb" then
        -- Fenced form: {blurb, class: X} ... {/blurb}. A pending list on the
        -- line above this opener is illegal per R13a (spec.txt:6647-6656),
        -- so it is rejected first, before anything of this branch's own is
        -- emitted -- exactly the rule U1's comment on reject_pending
        -- describes for every branch that does not consume the pending list.
        reject_pending("attribute list may not precede a fenced {blurb} opener")
        local head, decoratives = callout_classes(parsed.classes, cfg, file, rec.number)
        open_div(head, decoratives, "blurb")
        consume_until_close("blurb", rec.number)
      elseif #parsed.bare == 1 and parsed.bare[1] == "aside" then
        -- Fenced form: {aside, class: X} ... {/aside}. Sibling of the {blurb}
        -- branch above -- a preceding list is illegal here too (R13a,
        -- KTD7), rejected before this branch emits anything of its own --
        -- but open_aside (unlike callout_classes) has no default class to
        -- fall back to when parsed.classes is empty (R12).
        reject_pending("attribute list may not precede a fenced {aside} opener")
        open_aside(parsed.classes, rec.number)
        consume_until_close("aside", rec.number)
      else
        -- U5 inserts a branch here for the full directive table. Until it
        -- lands, every other attribute list -- including a bare-word
        -- directive line -- falls through to this generic swap, which is
        -- what keeps it from silently binding to whatever line happens to
        -- follow it.
        reject_pending()               -- a new list may not shadow an unused one
        pending, pending_line, pending_text = parsed, rec.number, text
        i = i + 1
      end

    elseif text:match("^A>") then
      -- A> run: unlike a fenced {aside} opener, a pending list here is
      -- APPLIED rather than rejected (KTD7) -- open_aside resolves it
      -- exactly as the fenced form does, falling back to the bare
      -- `::: {.aside}` shape when no list precedes the run at all (R11).
      if pending then
        open_aside(pending.classes, pending_line)
        pending, pending_line, pending_text = nil, nil, nil
      else
        open_aside({}, rec.number)
      end
      while i <= #lines and lines[i].text:match("^A>") do
        emit_body(strip_prefix(lines[i].text, "A>"))
        i = i + 1
      end
      emit(":::")

    elseif text:match("^B>") then
      -- B> run: consumes a pending list if one precedes it (R2), or defaults
      -- to `information` if not (R4). This swallows every consecutive B>
      -- line itself, so -- unlike the two branches below -- it advances `i`
      -- on its own and sits outside their shared trailing increment.
      local head, decoratives =
        callout_classes(pending and pending.classes or {}, cfg, file, pending_line or rec.number)
      pending, pending_line, pending_text = nil, nil, nil
      open_div(head, decoratives, "blurb")
      while i <= #lines and lines[i].text:match("^B>") do
        emit_body(strip_prefix(lines[i].text, "B>"))
        i = i + 1
      end
      emit(":::")

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
        -- Covers plain prose, blank lines, and A> lines before U4 adds its
        -- own branch above this one. A blank line no longer holds a pending
        -- list across it (KTD6): spec.txt:6647 requires the attribute list
        -- to directly precede its element with no blank line between them,
        -- so a blank goes through the same rejection as any other unclaimed
        -- case, not a special case that survives it.
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
