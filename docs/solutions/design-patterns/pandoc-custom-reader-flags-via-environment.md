---
title: "A pandoc custom reader cannot receive CLI flags through ReaderOptions"
date: "2026-08-08"
category: "design-patterns"
module: "src/markua.lua and bin/markua"
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Adding a command-line flag that changes how a pandoc custom reader behaves"
  - "Designing a Reader(inputs, opts) signature and deciding where per-run configuration comes from"
  - "A documented flag appears to have no effect and no error is raised"
tags:
  - "pandoc"
  - "custom-reader"
  - "readeroptions"
  - "cli-flags"
  - "environment-variables"
  - "dead-config"
related_components:
  - documentation
  - testing_framework
---

# A pandoc custom reader cannot receive CLI flags through ReaderOptions

## Context

A pandoc custom reader is a Lua script invoked as
`pandoc --from=src/markua.lua`. Its entry point receives
`Reader(inputs, opts)`, where `opts` is pandoc's `ReaderOptions` object. The
obvious way to add a `--lenient` flag is to read it off `opts`:

```lua
function Reader(inputs, opts)
  local cfg = config.defaults()
  if opts and opts.strict == false then   -- never fires
    cfg.strict = false
  end
  ...
```

This compiles, runs, raises nothing, and never works. The plan carried this
shape along with an `errors.report` function, unit tests for both its Strict
and Lenient branches, and code comments referring to "the documented
`--lenient` flag" — a fully built and tested feature reachable by nothing.

## Guidance

**`ReaderOptions` carries only pandoc's own fields.** Probed at pandoc 3.10.1,
the object exposes exactly: `abbreviations`, `columns`,
`default_image_extension`, `extensions`, `indented_code_classes`,
`standalone`, `strip_comments`, `tab_stop`, `track_changes`. Assigning an
unknown field raises `Cannot set unknown property`; reading one yields `nil`,
which is why the guard above fails silently rather than loudly.

There is also no pandoc CLI surface that forwards an arbitrary user flag into
a custom reader. `pandoc --lenient` is simply an unrecognized pandoc option.

**Pass custom flags through the environment, intercepted by a wrapper.** The
wrapper script owns the project's own flags; pandoc never sees them:

```sh
while [ $# -gt 0 ]; do
    case "$1" in
        --lenient)  MARKUA_LENIENT=1; shift ;;
        --config)   MARKUA_CONFIG="${2:?--config needs a path}"; shift 2 ;;
        --config=*) MARKUA_CONFIG="${1#--config=}"; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
export MARKUA_LENIENT MARKUA_CONFIG
exec pandoc --from="$root/src/markua.lua" "$@"
```

and the reader reads them:

```lua
if os.getenv("MARKUA_LENIENT") then
  cfg.strict = false
end
```

**Keep the `opts` check as well when it is meaningful.** `opts` is still the
right channel for anything pandoc genuinely owns, and a library caller
invoking `Reader` directly can pass a table of its own.

## Why This Matters

The failure is silent in both directions, which is what makes it expensive.

A user who reads the documentation, runs `markua --lenient chapter.md`, and
gets a hard error has no signal about why. Nothing warns that the flag was
ignored; pandoc does not reject it, because the wrapper passed it through as
an unknown argument and the reader never looked for it.

From the other side, the leniency code path had unit tests that passed. Tests
that exercise a function directly cannot tell you the function is unreachable
from the product. The whole Strict/Lenient design, its structured error type,
and its test suite were dead weight behind an `if` that could never be true.

This is the general shape of the hazard: **configuration that is plumbed but
not reachable**. It looks complete at every level a test can see.

## When to Apply

- Any time a pandoc custom reader or writer needs per-run configuration that
  is not one of pandoc's own reader options.
- Any time a flag is documented in a README, a plan, or a code comment before
  the wiring exists — the documentation is what makes the gap invisible, since
  readers assume the described behavior is real.
- More broadly: whenever a plugin runs inside a host process that owns the
  command line. The environment is usually the only channel that survives the
  boundary.

Not applicable when the setting is genuinely one pandoc already models —
`columns`, `tab_stop`, `extensions` and friends arrive on `opts` correctly and
need no wrapper.

## Examples

**Confirming the field is absent** rather than assuming it. `ReaderOptions` is a
userdata object, not a plain table, so it cannot be iterated with `pairs` —
probe it by reading and assigning directly:

```bash
cat > probe.lua <<'EOF'
function Reader(inputs, opts)
  io.stderr:write("opts.strict reads as: " .. tostring(opts.strict) .. "\n")
  local ok, err = pcall(function() opts.strict = false end)
  io.stderr:write("assigning opts.strict: " .. (ok and "succeeded" or tostring(err)) .. "\n")
  io.stderr:write("opts.columns reads as: " .. tostring(opts.columns) .. "\n")
  return pandoc.Pandoc({})
end
EOF
printf 'x\n' > in.md
pandoc --from=probe.lua --to=native in.md
```

Output under pandoc 3.10.1:

```text
opts.strict reads as: nil
assigning opts.strict: Cannot set unknown property.
opts.columns reads as: 72
```

The silent `nil` on read is the whole problem: a guard written as
`if opts.strict == false` never fires and never complains. A field pandoc does
own, like `columns`, arrives normally.

**A config file over the same channel.** Once the environment is the transport,
richer configuration follows the same path — `--config <file>` becomes
`MARKUA_CONFIG`, and the reader loads it in a sandboxed environment so a config
file is data rather than executable trust:

```lua
local chunk, err = loadfile(path, "t", {})   -- empty env: no io, no require
```

## Related

- `docs/plan.md` — Task 9 (reader entry point) and Task 12 (CLI wrapper) carry
  this wiring; the Global Constraints entry for `--lenient` names the mechanism.
