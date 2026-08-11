---
title: "`#` and `ipairs` cannot validate that a Lua table is an array"
date: "2026-08-10"
category: "design-patterns"
module: "src/markua/config.lua"
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Validating a table that arrived from outside the reader (a config file, parsed input, an override)"
  - "Writing a predicate that asks whether a Lua value is a list of strings"
  - "Reviewing any check written as `#t == count` or a bare `ipairs` scan"
tags:
  - "lua"
  - "validation"
  - "silent-failure"
  - "input-validation"
  - "config"
related_components:
  - testing_framework
---

# `#` and `ipairs` cannot validate that a Lua table is an array

## Context

`config.load_file` accepts a book's override file and must reject a value that
is not an array of strings. The obvious predicate looks right:

```lua
local count = 0
for _ in pairs(value) do count = count + 1 end
if count ~= #value then return false end          -- "is it contiguous?"
for _, item in ipairs(value) do                    -- "are the elements strings?"
  if type(item) ~= "string" then return false end
end
return true
```

Both halves are unsound, and they fail together in the same input.

## Guidance

**`#` is only defined at a border.** For a table with a hole, Lua may return any
index `n` where `t[n] ~= nil` and `t[n+1] == nil`. It is free to return the end
of the array part even when index 1 is missing. So a table with a gap *plus* a
stray hash key can make `#value` exactly equal the `pairs` count, and the
contiguity guard passes.

**`ipairs` then stops at the hole.** If index 1 is nil, it yields nothing, and
the element loop validates zero elements — vacuously true.

Verified on the pinned Lua 5.4.8:

```lua
local t = {}
for i = 1, 6 do t[i] = "c" .. i end
t[1] = nil
t.junk = "x"
-- pairs count = 6, #t = 6, count == #t, and ipairs yields 0 items
```

**Count the keys, then index every slot from 1 to that count.** One loop,
no reliance on a border:

```lua
local count = 0
for _ in pairs(value) do count = count + 1 end
for i = 1, count do
  if type(value[i]) ~= "string" then return false end
end
return true
```

This rejects holes (`value[i]` is nil), extra hash keys (they inflate `count`
past the contiguous run, so a later slot reads nil), and non-string elements,
with the same three lines.

## Why This Matters

The failure is silent and total. A config whose `callout_classes` had a gap was
**accepted**, and every callout class in the book then stopped resolving —
`is_callout_class` returned false for `warning`, `tip`, and everything else,
because the surviving entries were not where it looked. The book still built.
Every blurb quietly lost its class.

This is precisely the failure mode `AGENTS.md` forbids: unrecognized input must
be a hard error, never a silent pass-through.

## How it was found

Two independent reviewers disagreed. One reported the bypass with a fuzz run;
another claimed to have "proved structurally" that no table with a hole can make
`#` equal the key count. Running the specific input settled it in one command —
the first reviewer was right.

Reviewer confidence is not evidence. When two reviews conflict on a factual
claim about the runtime, execute the claim; do not weigh the arguments. That is
the same discipline as
[`execute-dont-read-when-reviewing-plans.md`](../conventions/execute-dont-read-when-reviewing-plans.md),
applied to review output rather than to a plan.

## When to Apply

- Any predicate that decides whether external data is a list.
- Any review of a check written as `#t == count`, or an `ipairs` scan used as
  proof that every element was seen.
- Not needed for a table the reader itself constructed and never exposed to
  outside input — there the shape is an invariant, not a question.
