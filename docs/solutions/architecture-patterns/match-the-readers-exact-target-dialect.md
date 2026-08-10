---
title: "Ground the scanner in the reader's exact target dialect, not in CommonMark"
date: "2026-08-09"
category: "architecture-patterns"
module: "src/markua/scanner.lua"
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - "Deciding whether a line, block, or construct counts as code in the pure-Lua pipeline"
  - "Writing a test expectation about what pandoc will do with generated markdown"
  - "Reasoning from the CommonMark spec about behavior this reader depends on"
  - "Adding container-aware handling (blockquotes, list items) to any transform"
tags:
  - "pandoc"
  - "commonmark"
  - "markdown-dialects"
  - "fence-awareness"
  - "differential-testing"
  - "silent-failure"
related_components:
  - testing_framework
  - documentation
---

# Ground the scanner in the reader's exact target dialect, not in CommonMark

## Context

`scanner.lua` exists to predict one thing: which lines pandoc will treat as
code, so no later transform rewrites a code sample as Markua. That makes it a
*model* of another parser. Its correctness is not "does it follow CommonMark" —
it is "does it agree with the parser the reader actually hands text to."

Those are not the same parser. `src/markua.lua` calls `pandoc.read` with
`markdown_strict` plus a specific extension list, and that dialect disagrees
with CommonMark on real inputs.

## Guidance

**Test against the exact format string the reader passes to `pandoc.read`,
not against `-f markdown` and not against the CommonMark spec.** The clearest
case found so far is an unclosed fence — text after a ` ``` ` that never closes:

- Under `markdown_strict` plus extensions, which is what this reader uses,
  pandoc emits a `Para`: the delimiter is ordinary literal text.
- Under `commonmark` or `gfm`, pandoc emits a `CodeBlock` running to the end
  of the document.

CommonMark specifies that an unclosed fence runs to the end of its containing
block. pandoc's markdown reader instead requires the fence to close before it
is a fence at all. A scanner built from the spec marks the remainder of the
document as code; pandoc renders it as prose. Every later transform then skips
Markua it should have converted.

**Use pandoc as a differential oracle rather than hand-reasoning the rules.**
Container nesting is where hand-reasoning fails fastest: blockquote prefixes and
list-item content columns both shift where a fence and an indented block begin.
Build a fixture corpus, ask pandoc which lines land in a `CodeBlock`, and diff
that against `scanner.scan`. That comparison found five disagreements that
reading the code did not, and it is what proved the fix.

**Freeze the oracle's answers as unit tests.** busted runs under system Lua,
where the `pandoc` global does not exist, so the differential run cannot be a
spec. Take pandoc's answers once, encode them as ordinary assertions, and say in
the test that the expectation is pandoc's own output rather than a derivation.

## Why This Matters

The scanner's failure mode is silent in both directions:

- **Under-detecting code** — a fenced block inside a `>` blockquote was
  invisible, so a manuscript quoting a chat log containing JSON would have had
  that JSON rewritten as Markua. The book still builds; the sample is wrong.
- **Over-detecting code** — a four-space line under a `1.` list marker is a lazy
  paragraph continuation to pandoc, not code. Marking it as code silently drops
  any `{ix: "term"}` an author indented there by habit.

Neither raises an error, and neither is visible without comparing against the
parser that actually consumes the output.

## The mistake repeats itself

This lesson was written after the unclosed-fence divergence, and then the same
error was made again in the same session, on the writer side. `to_pandoc_attr`
backslash-escaped a double quote in an attribute value, verified against
`pandoc -f markdown`. Under `markdown_strict` -- the format the reader actually
uses -- `all_symbols_escapable` is off, `\"` is not an escape, and pandoc
rejects the whole attribute block, leaking the `:::` delimiters into the prose.
Every book with a quoted title would have been affected.

Two things generalize:

- **`-f markdown` is not the target.** It is pandoc's permissive default and
  accepts constructs `markdown_strict` rejects. Reach for the reader's own
  format string every time, including when checking something that "obviously"
  works.
- **Check the output boundary, not just the input.** The first version of this
  document only covered the scanner, which reads. The writer side has the same
  exposure and a worse failure mode: a bad emission corrupts the document
  silently in every output format at once.

The general check is end-to-end: generate the construct with the module itself,
run it through every target writer, and assert both that the construct survives
into the AST -- not as literal text -- and that the binary formats stay
well-formed.

## When to Apply

- Any claim about what pandoc does with generated markdown. Run it, with the
  reader's own format string.
- Any transform that must skip code, especially one measuring indentation.
- Any value, id, or class the reader *emits* into generated markdown. Read the
  grammar in `Readers/Markdown.hs` rather than inferring it: an id is
  `many1 (alphaNum <|> oneOf "-_:.")`, a class is `letter` then the same set,
  and a value is carried by its quote character.
- Any expectation copied from the CommonMark spec — check the dialect first;
  the spec is the wrong authority when the target is `markdown_strict`.

It is overkill for constructs the two dialects agree on, which is most of them.
The point is to check rather than assume the agreement.
