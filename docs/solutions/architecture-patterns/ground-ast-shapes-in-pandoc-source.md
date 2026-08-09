---
title: "Read pandoc's source before choosing an AST annotation shape"
date: "2026-08-08"
category: "architecture-patterns"
module: "reader AST annotation layer and src/filters"
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - "Choosing the class and attribute names for a Span or Div that carries a Markua construct pandoc has no native node for"
  - "Deciding the order of classes on a Div, or any other detail a downstream writer might pattern-match on"
  - "Writing a plan or spec claim about how a pandoc writer, reader, or filter will behave"
  - "More than one pandoc reader already emits a structurally similar construct, and they disagree"
tags:
  - "pandoc"
  - "ast-conventions"
  - "index-spans"
  - "callout-divs"
  - "round-trip-testing"
  - "silent-failure"
  - "class-order"
related_components:
  - documentation
  - testing_framework
---

# Read pandoc's source before choosing an AST annotation shape

## Context

markua-pandoc is a delegating reader: it rewrites Markua-only syntax into
pandoc-flavored markdown in pure Lua, hands the result to `pandoc.read`, and
represents whatever pandoc has no native node for as an annotated `Span` or
`Div` that a later filter lowers into real output. Index entries and
blurb/aside callouts both work this way.

That leaves a design question with no obvious answer: what class and attribute
names should those annotations use? Pandoc has no index concept at all — the
only `"index"` hit anywhere in its `Writers/` tree is an unrelated EPUB
landmark name — so there is no writer to consult for "the" correct shape.

The natural move is to invent something reasonable-looking and write it into
the plan. That is what happened, twice, and both were wrong in ways that would
not have failed loudly.

**The decisions this produced are recorded in `docs/plan.md` under Key
Technical Decisions.** This document is about the method that produced them,
because the method is what transfers to the next such question.

> **Citation note.** Every `Readers/…` and `Writers/…` path below is in
> **pandoc's own repository** (`jgm/pandoc`, under `src/Text/Pandoc/`), not in
> this one. Line numbers were read at pandoc 3.10.1 and will drift; the
> function names are the durable anchor. Every behavior was also confirmed by
> running pandoc 3.10.1, not by reading alone.

## Guidance

Before writing a plan claim about how pandoc will treat an annotation, read
the pandoc source that consumes it. Specifically:

1. **Grep `Readers/` for every reader that already emits something
   analogous**, and compare them side by side rather than adopting the first
   one found. For index entries there were three, and they disagree:

   | Reader | Class | Term attribute | Hierarchy |
   | --- | --- | --- | --- |
   | Docx (`Readers/Docx.hs:478`) | `indexref` | `entry` | flat; `:` preserved |
   | AsciiDoc (`Readers/AsciiDoc.hs:394`) | `index` | `term` | comma-joined |
   | DocBook (`Readers/DocBook.hs:1262`) | `indexterm` | `primary` / `secondary` / `tertiary` | structured, 3 levels, plus `see` / `seealso` |

2. **Prefer the shape with the strongest verifiable property over the one that
   looks most standard.** The Docx shape was adopted because it round-trips:
   emit an `indexref` span, convert to DOCX, read it back with
   `pandoc -f docx -t native`, and the identical `Span` comes out. That is a
   far stronger oracle than grepping output XML for a literal `XE "`, which
   passes even when the field text inside is wrong.

3. **Check how the consuming writer behaves in every ordering the annotation
   might appear in**, not just that a matching reader exists. This is where
   the sharpest finding came from.

4. **Pin the chosen shape with a test that fails on regression** — an
   order-sensitive assertion, a round-trip check — rather than relying on a
   written rationale to stop a future contributor from "fixing" it back to
   whatever looks more natural.

5. **Borrow conventions and interfaces, never transcribe source.** Pandoc is
   GPL-2.0-or-later; this project is Apache-2.0. Behaviors are observed and
   reimplemented in Lua. The temptation to port an algorithm line-for-line is
   real and should be refused.

## Why This Matters

Two plan recommendations made without reading the source were wrong, and
neither would have announced itself.

**A hard-error rule for colliding delimiters had already been recommended and
accepted.** Reading `Writers/Markdown.hs:596` (`endlineLen`, which sizes a
code fence by scanning the body for the longest delimiter-only line and adding
one) and `:412-414` (fenced divs, sized by nesting depth) showed pandoc
resolves the identical collision by backslash-escaping the line — never by
erroring — and that the escaped form reads back to the identical AST. The rule
as written would have rejected manuscripts pandoc itself handles fine.

**An invented `.index` + `entry` span matched no pandoc reader exactly**,
which would have made the round-trip oracle unusable and left index entries in
a shape pandoc's own toolchain had never seen.

**The class-order hazard is the one that justifies the whole practice.**
Pandoc's DocBook writer (`Writers/DocBook.hs:210-225`) pattern-matches only
the *head* of a Div's class list:

```haskell
admonitions = ["caution","danger","important","note","tip","warning"]
(l:_) | l `elem` admonitions -> ...
```

Measured against pandoc 3.10.1:

- `Div ("",["tip","blurb"])` → `<tip><para>Careful.</para></tip>` — correct.
- `Div ("",["blurb","tip"])` → `<para>Careful.</para>` — same content, classes
  reordered, and the admonition is **silently gone**. No error, no warning, no
  type failure.

For a book-conversion tool this is worse than a crash. The content survives
and its meaning does not, so nothing downstream signals that anything went
wrong. No reviewer flagged it; it is not inferable from pandoc's documentation
or from using the CLI. Only reading the writer's pattern match surfaced it.

The same head-class shape is what pandoc's DocBook admonition parser
(`Readers/DocBook.hs:1163`) and its GitHub-alert reader independently produce —
`> [!NOTE]` becomes `Div ("",["note"],[]) [Div ("",["title"],[]) [...], Para [...]]`.
Two readers converging on a shape the writer accepts in exactly one order is
what turned "put the callout class first" from a style preference into a
tested requirement.

## When to Apply

Reach for this when:

- The construct has no native pandoc node, so *some* shape must be borrowed or
  invented.
- Several pandoc readers already emit something structurally similar. Multiple
  plausible candidates is precisely when picking by feel goes wrong — they all
  look equally reasonable from outside.
- A plan or task is about to assert how a writer or filter behaves, and that
  assertion has not been run. Not having read the source is a reason to soften
  the claim, not to withhold it.
- Guessing wrong fails *silently*. Silent failures are the ones normal testing
  misses, because catching them requires already knowing they exist.

It is overkill when pandoc's documentation states the behavior unambiguously,
or when the construct has one obvious native representation with no competing
candidates.

## Examples

**Free formats, discovered by reading rather than assumed.** Pandoc's HTML
writer prefixes unknown attributes with `data-` (`Writers/HTML.hs:706-712`), so
an index span already arrives in HTML and EPUB as
`<span class="indexref" data-entry="B-tree"></span>` with no filter written at
all. Two of the five promised output formats needed no work; that was invisible
until the writer was read.

**Separator alignment.** LaTeX's `\index{}` uses `!` as its subentry
separator — the same character Markua uses — so hierarchy passes through
verbatim. Word's `XE` field uses `:`, so only the Word filter translates. Two
formats, opposite amounts of work, and the difference is not guessable.

Note this one is *not* a pandoc-source claim like its neighbours: pandoc has no
LaTeX index writer to read, so `!` is a fact about the LaTeX `makeindex`
convention, confirmed from LaTeX documentation rather than from pandoc's tree.
The Word separator, by contrast, was confirmed by round-tripping through
pandoc's own Docx reader.

**Pandoc already ships a Markua writer.** `writeMarkua`
(`Writers/Markdown.hs:94`) maps Div `.blurb` to a `B>` line prefix and `.aside` to `A>`. This
project's class names already matched pandoc's own convention by luck, which
also means `markua → native → markua` is testable today. It is lossy in a known
way: `Div ("",["tip","blurb"])` writes as plain `B> Careful.`, dropping `tip`.

## Related

- `docs/plan.md` — Key Technical Decisions records what was decided; this doc
  records how.
- Issues #6 and #7 implement the callout-div and index-span shapes; #11 and #12
  implement the filters that consume them.
