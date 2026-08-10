# Residual Review Findings

Branch: `feat/scanner-and-attribute-parser`
Plan: `docs/plans/2026-08-09-001-feat-scanner-and-attribute-parser-plan.md`
Recorded: 2026-08-09

Findings from the code review of Phase 1 (Tasks 2 and 3), with the evidence that
produced them. Every one was reproduced by execution against pandoc 3.10.1, per
`docs/solutions/conventions/execute-dont-read-when-reviewing-plans.md`. Most are
open; the two under "Resolved after review" were fixed on this branch once that
same discipline was applied to the *decision* rather than only the finding, and
are kept because the reasoning transfers.

## The scanner has no notion of container nesting

`scanner.lua` tracks fenced and indented code against a flat, document-level
column measure. It has no concept of a blockquote prefix or a list-item content
offset, so it disagrees with pandoc wherever code is nested inside a container.
Three findings share this one root cause; fixing it means teaching the scanner
about container prefixes, which changes R6 and R7 and deserves its own unit.

- **P1 — fenced code inside a blockquote is invisible.** `fence_parts` strips
  only leading spaces, never a blockquote `>` prefix. pandoc parses
  ``> ```python`` / `> {"k": 1}` / ``> ``` `` as a `BlockQuote` containing a real
  `CodeBlock`; `scanner.scan` marks all three lines `in_code = false`. Once a
  consumer exists, a manuscript quoting a forum post or chat log that contains a
  JSON snippet has that snippet rewritten as Markua. The book still builds and
  the sample comes out wrong — the exact silent corruption this module exists to
  prevent.

- **P2 — a 4-column indent inside a list item is misclassified as code.** Under a
  3-column marker (`1.` plus a space), CommonMark needs 3+4=7 columns to open a nested code
  block; 4 columns is a lazy paragraph continuation. pandoc parses
  `1. item one` / blank / a four-space-indented `{timeout: 30}` as a `Para` inside the list item;
  the scanner reports `in_code = true`. An author indenting a continuation line
  by the conventional four spaces under a numbered step gets that line skipped by
  every later Markua pass, so an attribute such as `{ix: "term"}` is silently
  dropped instead of converted.

- **P3 — a fence under a wide list marker loses its info string.** At a two-digit `10.` marker's 4-column offset, `fence_parts` rejects the delimiter as over-indented.
  `in_code` still ends up correct via the indented-code branch, but `fence` and
  `info` are never set, so the language pandoc attaches to the block is lost to
  any consumer reading `record.info`.

## Resolved after review: attribute-value recovery and name representability

Both items below started as residuals and were fixed on this branch after
checking what the surrounding formats actually do. They are kept here because
the reasoning is the useful part.

**The unterminated quoted value no longer swallows the next field.** It did:
`attributes.parse('{title: "abc, class: tip}')` merged everything into the title
and `class: tip` vanished silently. The fix was not the obvious one. Raising when
the quote never closes would also reject `{title: 5" pipe}`, which parses
correctly today, so it looked like it needed a Markua-spec ruling on what opens a
quoted value. Measuring pandoc dissolved the question: pandoc never errors here.
`{#h title="abc class=tip}` yields the value `"abc` *and* still applies the class
`tip` — an unclosed quote simply stops delimiting. `split_fields` now recovers
the same way, which ends the data loss and keeps every input that worked before.

**An unrepresentable id or class is now a hard error.** `{#my id, .a class}`
re-emitted as `{#my id .a class}`, and pandoc rejects that whole attribute block
and renders it as literal text — leaking braces into the prose and dropping the
class as well as the id. Values can always be carried by escaping; ids and
classes have no escape syntax at all, so `to_pandoc_attr` raises through `errors`
naming the offending name. Sanitizing was rejected: it would silently rewrite an
anchor the author cross-references elsewhere.

The split those two produced — parse permissively, emit strictly — is recorded as
a Key Technical Decision in `docs/plan.md`. It follows the formats on each side:
markdown never fails to parse, while DocBook and EPUB treat malformed markup as
fatal.

## Testing gaps

- No scanner coverage for code nested in a blockquote or a list item (the gaps
  above have no regression test either way).
- No attribute-parser test for duplicate keys in one attribute list (current
  behavior is last-wins, untested).
- No test composes `parse` into `to_pandoc_attr` for an escape-bearing value. The
  composition trap is documented in `attributes.lua` but not pinned by a test,
  because the correct composed output depends on where the unescape step lands —
  still open, and owned by whichever consumer first needs the round trip.
- An id that is representable for pandoc may still be invalid downstream: XML
  types `xml:id` as an `NCName`, so a leading digit (`{#3things}`) is fine for
  pandoc, HTML and LaTeX but not for DocBook or EPUB. pandoc's DocBook writer
  passes such an id through unsanitized. Not guarded here, because pandoc itself
  does not guard it and rejecting those ids would refuse documents the other
  three writers handle correctly.

## Review context

Reviewers: correctness, project-standards, testing, maintainability, learnings,
adversarial. Applied on this branch: the table-driven fence patterns, the
`parse`/`to_pandoc_attr` composition note, the `class:` negative assertion, and
the trailing-record `number` and CRLF round-trip tests.

The cross-model adversarial peer pass did not run: no allowlisted peer route is
configured for this checkout, so the adversarial lens ran in-process. Its
agreement with the other reviewers is therefore same-model, not independent
cross-model corroboration.
