--- Block-level Markua to pandoc-markdown rewrites.
--
-- Handles the block-level constructs Markua layers on top of CommonMark: the
-- pending attribute-list lifecycle every construct below binds into, blurbs
-- and asides (each with a run-of-lines form and a fenced form), the eight
-- documented blurb sugar prefixes, and the closed set of bare-word matter and
-- insertion directives.
--
-- Blurbs (`B>` runs and `{blurb, class: X} ... {/blurb}`) and asides (`A>`
-- runs and `{aside} ... {/aside}`) share their consume-until-close loop and
-- class-resolution machinery, but differ in two ways. A bare blurb defaults
-- to callout class `information` (R4); a bare aside has no callout-class
-- default at all (R11) and stays a plain `::: {.aside}`. And a pending
-- attribute list ahead of an `A>` run is APPLIED, while one ahead of a fenced
-- `{aside}` opener is REJECTED -- mirroring the fenced `{blurb}` prohibition
-- (KTD7).
--
-- The eight documented sugar prefixes (C/D/E/I/Q/T/W/X>) share one dispatch
-- with `B>` itself, table-driven (KTD10) since Lua patterns have no
-- alternation. A pending attribute list's explicit class overrides a
-- prefix's implied one rather than conflicting with it, reported as a
-- warning rather than a hard error when the two disagree (KTD10a).
--
-- Bare-word directives (the `DIRECTIVES` table below) each lower to a
-- self-closing marker, ahead of the generic "unclaimed attribute list"
-- fallback this pass uses last -- a bare word outside that table, e.g.
-- "nonsense", falls through to that fallback and is rejected exactly as any
-- other unrecognized list is. `frontmatter` rides the `matter` family even
-- though the spec calls the directive nonexistent and asks a Processor to
-- ignore it (KTD5) -- emitting an inert marker *is* ignoring it while
-- preserving the author's intent for a downstream filter. `pagebreak` rides
-- `insert` alongside the front-/back-matter insertion directives rather than
-- getting a marker family of its own, since a third family with one member
-- buys nothing (KTD4).
local attributes = require("src.markua.attributes")
local config = require("src.markua.config")
local errors = require("src.markua.errors")

local M = {}

-- Strip a construct's line prefix and the one space Markua allows after it
-- ("B> text" and "B>text" both mean the same body). Shared by every prefixed
-- construct (B>, A>, and the eight sugar prefixes), so the one-space rule
-- lives in one place.
local function strip_prefix(text, prefix)
  local body = text:sub(#prefix + 1)
  return (body:gsub("^ ", ""))
end

-- Sugar prefix -> implied callout class (R5). `B` carries no implied class of
-- its own: it is the general blurb form, falling back to a pending list's
-- class or, absent one, R4's `information` default. Every other prefix names
-- the class Markua 0.30 documents for it. Table-driven rather than a branch
-- chain (KTD10) -- Lua patterns have no alternation, and scanner.lua and
-- config.lua both already hold their own alternatives as data, not a chain of
-- `elseif`s.
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
  -- FIX 4: the lenient recovery below adopts the author's own first class as
  -- the div's head so their text survives -- but open_div runs that head
  -- through attributes.check_name before emitting, which raises
  -- UNCONDITIONALLY on a name pandoc's attribute grammar cannot represent
  -- (e.g. "3bad"). A class that is BOTH unregistered AND unrepresentable
  -- therefore still aborted under --lenient before this check existed,
  -- reintroducing the exact strict/lenient asymmetry the comment above
  -- already fixed once for the plain-unknown-class case. is_valid_name is
  -- the non-raising sibling of check_name (attributes.lua) that lets this
  -- function ask the question instead of finding out by crashing.
  local head = classes[1]
  local representable = head ~= nil and attributes.is_valid_name("class", head)
  local message = "unknown callout class '" .. table.concat(classes, "', '") .. "'" .. hint
  if not representable then
    -- Name both faults in one message: an author staring at "'3bad' unknown"
    -- alone, after the div silently became .information instead of .3bad,
    -- would go looking for a registration problem and never find the real
    -- one -- that the class can't be spelled in pandoc's attribute syntax at
    -- all, registered or not.
    message = "unknown and unrepresentable callout class '" .. table.concat(classes, "', '") .. "'" .. hint
  end
  errors.report(cfg, file, line, message)
  if not representable then
    -- Same shape callout_classes({}, ...) returns for an empty class list:
    -- no decoratives, since an unrepresentable name cannot ride along as one
    -- either -- it would hit the identical check_name raise one slot later.
    --
    -- Returning nil rather than "information" leaves the fallback class to
    -- the caller, because the two constructs disagree on what it should be:
    -- a blurb defaults to `information` (R4), while a bare aside carries no
    -- callout class at all (R11). Answering "information" here for both gave
    -- a recovered aside `::: {.information .aside}`, which the callout filter
    -- then styles as a blurb -- turning a lenient recovery into wrong output
    -- rather than merely degraded output.
    return nil, {}
  end
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
  local head, decoratives = resolve_callout_class(classes, cfg, file, line)
  -- A nil head is the lenient unrepresentable-class recovery declining to
  -- pick a fallback (see resolve_callout_class). A blurb's is `information`,
  -- the same default an empty class list takes (R4).
  if head == nil then
    return "information", {}
  end
  return head, decoratives
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
    if not config.is_index_key(cfg, key) then
      return false
    end
    count = count + 1
  end
  return count > 0
end

function M.transform(lines, cfg, file)
  local out = {}
  local pending = nil        -- attribute list awaiting its element
  local pending_text = nil   -- the raw line, for verbatim re-emission
  local i = 1

  local function emit(s)
    out[#out + 1] = s
  end

  -- A body line beginning with a run of 3+ colons opens or closes a fenced
  -- div in pandoc's own grammar REGARDLESS of what follows the colons on
  -- that line -- verified against the reader's exact TARGET_FORMAT:
  -- ":::text" (no space, no braces) opens a div named "text" exactly like
  -- ":::" alone closes whichever one is open. A bare-":::" match alone (FIX
  -- 2) therefore missed the far more common author shape "::: {.example}":
  -- that line opened a real NESTED Div this pass never intended, and the
  -- construct's own generated closer then closed the INNER div instead of
  -- the one this pass opened, leaving everything after it swallowed into
  -- the outer div with a "closing implicitly" warning at EOF -- silent
  -- structural corruption, not merely misplaced text. So every line whose
  -- content starts with ":::" is escaped here, not only a bare colon run.
  --
  -- This does NOT imitate pandoc's own markdown writer: writing a real
  -- nested Div back out, pandoc WIDENS the outer fence to "::::" rather than
  -- escaping the inner one (confirmed with `pandoc -f <TARGET_FORMAT> -t
  -- markdown` against a nested-div AST). Widening is the writer's fix for a
  -- Div node it already knows is nested; it has no bearing here, because
  -- this pass is not rendering a Div -- it is passing through a line of an
  -- author's prose that happens to be ":::"-shaped. The actual reason to
  -- escape it is narrower and unrelated to that writer behavior: an
  -- author's literal ":::"-shaped body line must not be able to open or
  -- close a div this pass generates elsewhere in the same document.
  --
  -- "$$" gets the same treatment for the same underlying reason -- it is a
  -- display-math delimiter this pass emits elsewhere -- but stays bare-only
  -- (`^%s*%$%$%s*$`, not widened to "anything starting with $$"): unlike
  -- ":::", pandoc's tex_math_dollars syntax has no attribute-string form
  -- that turns "$$ something" into a different construct, so there is
  -- nothing analogous to ":::{.class}" for "$$" to collide with.
  local function emit_body(s)
    if s:match("^%s*:::+") or s:match("^%s*%$%$%s*$") then
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
  -- rendered as `id="..."`. Every caller of this function threads one
  -- through: the sugar-prefix branch below, the A> branch and fenced
  -- {aside} branch via open_aside, and the fenced {blurb} branch directly
  -- (FIX 5) -- an `id:` on any of the five construct paths reaches its div
  -- rather than silently losing the cross-reference anchor on three of them.
  --
  -- `head` and every entry of `decoratives`, plus `id` when given, are
  -- validated through attributes.check_name before anything is emitted --
  -- the same check attributes.to_pandoc_attr already applies to every id and
  -- class it renders. This path builds its own `::: {...}` text directly
  -- rather than going through to_pandoc_attr, so it must call that
  -- validation itself: without it, an author's `{class: "tip 3bad"}` reaches
  -- pandoc.read as `::: {.tip .3bad .blurb}`, and pandoc rejects the WHOLE
  -- attribute block on the illegal class, destroying the blurb and leaking
  -- literal braces into the finished book -- exactly the failure AGENTS.md's
  -- "never pass through as literal braces" rule forbids. check_name raises
  -- unconditionally rather than going through errors.report, matching its
  -- own behavior inside to_pandoc_attr: an id or class pandoc's attribute
  -- syntax cannot represent is a "cannot be rendered" fault, not an
  -- "unrecognized Markua construct" one that --lenient is meant to downgrade.
  --
  -- `marker` is never validated: it is always one of this module's own
  -- literals ("blurb" / "aside"), never author input.
  local function open_div(head, decoratives, marker, id, line)
    if id then
      attributes.check_name("id", id, file, line)
    end
    attributes.check_name("class", head, file, line)
    for _, c in ipairs(decoratives) do
      attributes.check_name("class", c, file, line)
    end
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
  --
  -- `id`, when given, is threaded through to open_div in the non-empty-class
  -- branch, and validated and emitted directly in the bare-`::: {.aside}`
  -- branch (FIX 5) -- an `id:` above an `A>` run or a fenced `{aside}` no
  -- longer vanishes the way it did before this function accepted one.
  local function open_aside(classes, line, id)
    if not classes or #classes == 0 then
      if id then
        attributes.check_name("id", id, file, line)
        emit("::: {#" .. id .. " .aside}")
      else
        emit("::: {.aside}")
      end
    else
      local head, decoratives = resolve_callout_class(classes, cfg, file, line)
      if head == nil then
        -- Lenient recovery declined to pick a fallback class. An aside's is
        -- no callout class at all (R11), not the blurb's `information`, so
        -- recover to the same bare shape an aside with no attribute list
        -- takes -- keeping any id the author did supply.
        open_aside(nil, line, id)
      else
        open_div(head, decoratives, "aside", id, line)
      end
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
      -- FIX 3: a code sample nested inside this fenced form can legitimately
      -- contain a ":::"-shaped line (AGENTS.md's fence-awareness rule --
      -- content inside a fenced code block is never Markua). The closer
      -- check above already branches on `in_code`; emission must match it,
      -- or a code line reaches emit_body and gets a spurious backslash
      -- escape injected into what the author wrote verbatim.
      if lines[i].in_code then
        emit(lines[i].text)
      elseif attributes.is_attribute_line(lines[i].text) then
        -- A body line is not exempt from the unknown-construct rule. Emitting
        -- it verbatim let `{nonsense}` inside a blurb reach the book as
        -- literal braces, while the identical line one level up raised --
        -- the same input silently meaning two different things depending on
        -- where it sat. Index markers are the one attribute line that
        -- legitimately passes through here, because inline.transform runs
        -- after this pass and owns them (R23).
        --
        -- Everything else is refused rather than interpreted: what a nested
        -- directive or a second attribute list should MEAN inside a callout
        -- body is undecided, and inventing a nesting semantic to avoid an
        -- error would be a worse answer than saying so.
        local body_parsed = attributes.parse(lines[i].text, file, lines[i].number)
        if is_index_only(body_parsed, cfg) then
          emit(lines[i].text)
        else
          errors.report(cfg, file, lines[i].number, string.format(
            "an attribute list other than an index marker is not supported inside a {%s} body: %s",
            marker, lines[i].text))
          emit(lines[i].text)   -- lenient only; preserve the author's line
        end
      else
        emit_body(lines[i].text)
      end
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

  -- Consume every consecutive line sharing `prefix`, emitting each one's body
  -- through emit_body, then close with ":::". Shared by the A> branch and the
  -- blurb-prefix branch below -- both open their div first, then hand off
  -- here to swallow their own run and close it. "A>" is a fixed literal, so
  -- `text:match("^A>")` (the run's opening condition) and the `sub`-based
  -- comparison this loop uses are equivalent for it; using `sub` uniformly
  -- means one implementation serves every prefix, fixed or table-driven
  -- alike. Advances `i` on its own, past every line it consumes, exactly
  -- like consume_until_close above.
  local function consume_prefixed_run(prefix)
    while i <= #lines and lines[i].text:sub(1, #prefix) == prefix do
      emit_body(strip_prefix(lines[i].text, prefix))
      i = i + 1
    end
    emit(":::")
  end

  -- Nothing may see a pending attribute list and quietly forget it. Every
  -- exit from the pending state goes through here, so an unclaimed list
  -- aborts with its own line number instead of leaking braces into the book
  -- or vanishing (R21). Called as the FIRST action of any branch that does
  -- not consume the pending list itself -- the branches that do consume it
  -- (the heading attach, and the B>, A>, and sugar-prefix branches) are
  -- untouched by this rule.
  local function reject_pending(reason)
    if not pending then
      return
    end
    local text = pending_text
    errors.report(cfg, file, pending.line,
      (reason or "attribute list applies to nothing") .. ": " .. text)
    -- Only reached when cfg.strict is false. Re-emit verbatim, at the
    -- position of the line that disqualified it: leniency preserves the
    -- author's text and never reorders or deletes it (R22). Resolving this
    -- in the same loop iteration as the disqualifying line -- rather than
    -- tracking and rewriting an output index -- is what keeps that true
    -- without bookkeeping: the append lands here, before whatever that line
    -- goes on to emit.
    emit(text)
    pending, pending_text = nil, nil
  end

  while i <= #lines do
    local rec = lines[i]
    local text = rec.text
    local blurb_prefix = find_blurb_prefix(text)

    if rec.in_code then
      -- A pending list does not survive a fence: without this, {class: tip}
      -- above a fenced code sample silently jumps the fence and binds to
      -- whatever construct follows it, so a W> after the fence renders as a
      -- tip -- wrong class, no error, in strict mode (FIX 1). This is the
      -- only branch in the dispatch that neither consumes `pending` nor
      -- rejects it; every other non-consuming branch calls reject_pending as
      -- its first action, per that function's own comment.
      reject_pending("attribute list precedes a fenced code block")
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
        -- emitted -- exactly the rule reject_pending's own comment describes
        -- for every branch that does not consume the pending list.
        reject_pending("attribute list may not precede a fenced {blurb} opener")
        local head, decoratives = callout_classes(parsed.classes, cfg, file, rec.number)
        -- FIX 5: `id:` lands in parsed.keyvals.id (attributes.parse's home
        -- for Markua's own id syntax); parsed.id is only ever set by the
        -- `#id` shorthand pandoc uses and Markua's fenced-opener syntax does
        -- not. Checking both, as the sugar-prefix branch below already does,
        -- means the fenced {blurb, id: s} ... {/blurb} form produces the
        -- identical div the plan's R3 requires instead of dropping the
        -- anchor.
        open_div(head, decoratives, "blurb", parsed.id or parsed.keyvals.id, rec.number)
        consume_until_close("blurb", rec.number)
      elseif #parsed.bare == 1 and parsed.bare[1] == "aside" then
        -- Fenced form: {aside, class: X} ... {/aside}. Sibling of the {blurb}
        -- branch above -- a preceding list is illegal here too (R13a,
        -- KTD7), rejected before this branch emits anything of its own --
        -- but open_aside (unlike callout_classes) has no default class to
        -- fall back to when parsed.classes is empty (R12).
        reject_pending("attribute list may not precede a fenced {aside} opener")
        open_aside(parsed.classes, rec.number, parsed.id or parsed.keyvals.id)  -- FIX 5
        consume_until_close("aside", rec.number)
      elseif #parsed.bare == 1 and DIRECTIVES[parsed.bare[1]] then
        -- Bare-word directive. A pending list does not bind to a directive
        -- line -- mirroring the fenced {blurb}/{aside} prohibition (R13a) --
        -- so it is rejected first, exactly like every other branch that does
        -- not consume the pending list itself; a leftover {class: X} above
        -- {pagebreak} raises instead of silently vanishing.
        reject_pending("attribute list does not precede a directive")
        local word = parsed.bare[1]
        local kind = DIRECTIVES[word]
        -- A directive marker carries only its bare word (R18), so any other
        -- attribute on the line has nowhere to go. Emitting the marker and
        -- dropping the rest silently loses author intent -- `{pagebreak,
        -- id: lost}` would discard an anchor another part of the book
        -- cross-references. Report instead, so strict aborts and --lenient
        -- keeps the author's line intact rather than a lossy marker.
        local extras = {}
        if parsed.id then
          extras[#extras + 1] = "#" .. parsed.id
        end
        for _, c in ipairs(parsed.classes) do
          extras[#extras + 1] = "." .. c
        end
        local keys = {}
        for k in pairs(parsed.keyvals) do
          keys[#keys + 1] = k
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
          extras[#extras + 1] = k
        end
        if #extras > 0 then
          errors.report(cfg, file, rec.number, string.format(
            "the %s directive takes no other attributes, but this line carries %s",
            word, table.concat(extras, ", ")))
          -- Only reached under --lenient: keep the author's line rather than
          -- a marker that dropped half of what they wrote.
          emit(text)
        else
          -- The class and the attribute key are both the kind; the value is
          -- the bare word verbatim, so no name is translated anywhere (R18).
          -- Self-closing, not a wrapper (R16, R17): confirmed against the
          -- reader's own TARGET_FORMAT that prose following the marker is a
          -- SIBLING Para, not nested inside an empty Div (KTD3).
          emit(string.format('::: {.%s %s="%s"}', kind, kind, word))
          emit(":::")
        end
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
        pending, pending_text = parsed, text
        i = i + 1
      end

    elseif text:match("^A>") then
      -- A> run: unlike a fenced {aside} opener, a pending list here is
      -- APPLIED rather than rejected (KTD7) -- open_aside resolves it
      -- exactly as the fenced form does, falling back to the bare
      -- `::: {.aside}` shape when no list precedes the run at all (R11).
      if pending then
        open_aside(pending.classes, pending.line, pending.id or pending.keyvals.id)  -- FIX 5
        pending, pending_text = nil, nil
      else
        open_aside({}, rec.number)
      end
      consume_prefixed_run("A>")

    elseif blurb_prefix then
      -- B> run and the eight sugar prefixes share one path (KTD10): they
      -- differ only in what class an EMPTY pending list resolves to. A
      -- pending list carrying its own class always wins over the prefix's
      -- implied one (KTD10a, R5a) -- the spec's own worked example renders
      -- {class: tip} above W> as a tip blurb, not a failed conversion -- so
      -- disagreement between the two is a warning, not a hard error, fired
      -- only when they actually differ. consume_prefixed_run swallows every
      -- consecutive line sharing the SAME prefix and closes the div, so --
      -- unlike the branches below -- it advances `i` on its own and sits
      -- outside their shared trailing increment.
      local pending_classes = pending and pending.classes or {}
      -- Markua's own id syntax is the `id:` key (KTD10b), which
      -- attributes.parse lands in .keyvals.id; `.id` itself is only ever set
      -- by the `#id` shorthand pandoc uses and Markua does not. Checking
      -- both costs nothing and means an id reaches the div regardless of
      -- which shape produced it.
      local id = pending and (pending.id or pending.keyvals.id) or nil
      local head, decoratives, applied_line
      if #pending_classes > 0 then
        applied_line = pending.line
        head, decoratives = callout_classes(pending_classes, cfg, file, applied_line)
        -- Warn only when the head is a class the AUTHOR actually named. Under
        -- --lenient an unregistered-and-unrepresentable class resolves to the
        -- `information` fallback, and reporting that as "explicit class
        -- 'information' overrides W>'s implied class 'warning'" names a class
        -- the author never wrote -- a second, contradictory diagnostic on top
        -- of the accurate one resolve_callout_class already emitted.
        local head_is_authors = false
        for _, c in ipairs(pending_classes) do
          if c == head then
            head_is_authors = true
            break
          end
        end
        if head_is_authors and blurb_prefix.class and head ~= blurb_prefix.class then
          errors.warn(file, applied_line, string.format(
            "explicit class '%s' overrides %s's implied class '%s'", head, blurb_prefix.prefix, blurb_prefix.class),
            cfg.sink)
        end
      elseif blurb_prefix.class then
        applied_line = rec.number
        head, decoratives = blurb_prefix.class, {}
      else
        applied_line = rec.number
        head, decoratives = callout_classes({}, cfg, file, applied_line)
      end
      pending, pending_text = nil, nil
      open_div(head, decoratives, "blurb", id, applied_line)
      consume_prefixed_run(blurb_prefix.prefix)

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
          -- No explicit line: to_pandoc_attr falls back to parsed.line,
          -- which is the same position pending.line already carries.
          emit(text .. " " .. attributes.to_pandoc_attr(pending, file))
          pending, pending_text = nil, nil
        end
      else
        -- Covers plain prose and blank lines; A> lines are handled by their
        -- own branch above, not here. A blank line no longer holds a
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
