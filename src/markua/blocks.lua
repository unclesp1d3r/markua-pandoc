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
-- fenced opener is (KTD7). U3 adds the C/D/E/I/Q/T/W/X> sugar prefixes,
-- table-driven alongside `B>` in one dispatch (KTD10); a pending attribute
-- list's explicit class overrides a prefix's implied one rather than
-- conflicting with it, reported as a warning rather than a hard error
-- (KTD10a). U5 adds the closed bare-word directive table (`DIRECTIVES`
-- below): every recognized bare word lowers to a self-closing marker, ahead
-- of the generic "unclaimed attribute list" fallback U1 builds -- a bare word
-- outside that table, e.g. "nonsense", still falls through to that fallback
-- and is rejected exactly as any other unrecognized list is.
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

-- Sugar prefix -> implied callout class (R5). `B` carries no implied class
-- of its own: it is the general form U2 already covers, falling back to a
-- pending list's class or, absent one, R4's `information` default. Every
-- other prefix names the class Markua 0.30 documents for it. Table-driven
-- rather than a branch chain (KTD10) -- Lua patterns have no alternation,
-- and scanner.lua and config.lua both already hold their own alternatives as
-- data, not a chain of `elseif`s.
local BLURB_PREFIXES = {
  { prefix = "B>", class = nil },
  { prefix = "C>", class = "center" },
  { prefix = "D>", class = "discussion" },
  { prefix = "E>", class = "error" },
  { prefix = "I>", class = "information" },
  { prefix = "Q>", class = "question" },
  { prefix = "T>", class = "tip" },
  { prefix = "W>", class = "warning" },
  { prefix = "X>", class = "exercise" },
}

-- Which entry (if any) opens `text` as a blurb run. A loop over the table
-- above, for the same reason the table exists: Lua's patterns cannot
-- alternate, so this cannot collapse into one combined pattern.
local function find_blurb_prefix(text)
  for _, entry in ipairs(BLURB_PREFIXES) do
    if text:sub(1, #entry.prefix) == entry.prefix then
      return entry
    end
  end
  return nil
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

-- Bare-word directive -> which self-closing marker family it emits (R14,
-- R15). One table, not two, so the whole recognized set is enumerable in one
-- place -- that is what makes R19's hard error trustworthy: a caller can see
-- every legal bare word by reading this table rather than reconciling two.
--
-- `frontmatter` is listed under "matter" even though spec.txt:2288 says the
-- directive "does not exist" and a Processor "should ignore it if it is
-- encountered": real manuscripts write it anyway, and the spec's own remedy
-- is to ignore rather than reject. Emitting an inert marker *is* ignoring it
-- while preserving the author's intent for a downstream filter (KTD5).
--
-- `pagebreak` is listed under "insert" rather than getting a marker family of
-- its own: spec.txt:2219 groups it with neither the structural pair nor the
-- two closed insertion lists, but it inserts something at a point, which is
-- what `.insert` already means, and a third family with one member buys
-- nothing (KTD4).
local DIRECTIVES = {
  mainmatter = "matter",
  backmatter = "matter",
  frontmatter = "matter",
  pagebreak = "insert",
  ["half-title"] = "insert",
  ["series-title"] = "insert",
  ["title-page"] = "insert",
  copyright = "insert",
  dedication = "insert",
  epigraph = "insert",
  toc = "insert",
  figures = "insert",
  tables = "insert",
  index = "insert",
  ["exercise-answers"] = "insert",
  ["quiz-answers"] = "insert",
}

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
  --
  -- `id`, when given, leads the attribute block as `#id` -- the shape
  -- `attributes.to_pandoc_attr` already uses, and one the pandoc oracle
  -- confirms sets the Div's identifier identically to a Markua `id:` key
  -- rendered as `id="..."`. U3 is the first caller to pass one, carrying a
  -- pending list's id onto a sugar-prefix blurb (R5a) rather than dropping
  -- it the way the un-widened class-only signature would have.
  local function open_div(head, decoratives, marker, id)
    local parts = {}
    if id then
      parts[#parts + 1] = "#" .. id
    end
    parts[#parts + 1] = "." .. head
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
      elseif #parsed.bare == 1 and DIRECTIVES[parsed.bare[1]] then
        -- Bare-word directive (U5). A pending list does not bind to a
        -- directive line -- mirroring the fenced {blurb}/{aside} prohibition
        -- (R13a) -- so it is rejected first, exactly like every other branch
        -- that does not consume the pending list itself; a leftover
        -- {class: X} above {pagebreak} raises instead of silently vanishing.
        reject_pending("attribute list does not precede a directive")
        local word = parsed.bare[1]
        local kind = DIRECTIVES[word]
        -- The class and the attribute key are both the kind; the value is
        -- the bare word verbatim, so no name is translated anywhere (R18).
        -- Self-closing, not a wrapper (R16, R17): confirmed against the
        -- reader's own TARGET_FORMAT that prose following the marker is a
        -- SIBLING Para, not nested inside an empty Div (KTD3).
        emit(string.format('::: {.%s %s="%s"}', kind, kind, word))
        emit(":::")
        i = i + 1
      elseif #parsed.bare == 1 then
        -- A lone bare word that reached here is not `blurb`, not `aside`,
        -- and not in DIRECTIVES, so it is an unrecognized directive and
        -- nothing downstream will claim it (R19). Say that, rather than
        -- letting it fall through to the generic swap below: that path
        -- reports "attribute list precedes no element it can apply to",
        -- which misdescribes a typo like {indx} as a placement problem and
        -- sends the author looking at the wrong line. Naming the word and
        -- the real fault is the entire value of the hard error -- a
        -- misdiagnosing abort is barely better than the silent
        -- pass-through AGENTS.md forbids. Reported, not raised, so
        -- `--lenient` still downgrades it like every other unknown
        -- construct.
        reject_pending()
        errors.report(cfg, file, rec.number,
          "unrecognized directive '" .. parsed.bare[1] .. "'")
        emit(text)                     -- lenient only; preserve the author's line
        i = i + 1
      else
        -- Every other attribute list falls through to this generic swap,
        -- which is what keeps it from silently binding to whatever line
        -- happens to follow it (R21).
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

    elseif find_blurb_prefix(text) then
      -- B> run and the eight sugar prefixes (U3) share one path (KTD10):
      -- they differ only in what class an EMPTY pending list resolves to.
      -- A pending list carrying its own class always wins over the prefix's
      -- implied one (KTD10a, R5a) -- the spec's own worked example renders
      -- {class: tip} above W> as a tip blurb, not a failed conversion -- so
      -- disagreement between the two is a warning, not a hard error, fired
      -- only when they actually differ. This swallows every consecutive
      -- line sharing the SAME prefix itself, so -- unlike the branches below
      -- -- it advances `i` on its own and sits outside their shared trailing
      -- increment.
      local entry = find_blurb_prefix(text)
      local pending_classes = pending and pending.classes or {}
      -- Markua's own id syntax is the `id:` key (KTD10b), which
      -- attributes.parse lands in .keyvals.id; `.id` itself is only ever set
      -- by the `#id` shorthand pandoc uses and Markua does not. Checking
      -- both costs nothing and means an id reaches the div regardless of
      -- which shape produced it.
      local id = pending and (pending.id or pending.keyvals.id) or nil
      local head, decoratives
      if #pending_classes > 0 then
        head, decoratives = callout_classes(pending_classes, cfg, file, pending_line)
        if entry.class and head ~= entry.class then
          errors.warn(file, pending_line, string.format(
            "explicit class '%s' overrides %s's implied class '%s'", head, entry.prefix, entry.class), cfg.sink)
        end
      elseif entry.class then
        head, decoratives = entry.class, {}
      else
        head, decoratives = callout_classes({}, cfg, file, rec.number)
      end
      pending, pending_line, pending_text = nil, nil, nil
      open_div(head, decoratives, "blurb", id)
      while i <= #lines and lines[i].text:sub(1, #entry.prefix) == entry.prefix do
        emit_body(strip_prefix(lines[i].text, entry.prefix))
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
