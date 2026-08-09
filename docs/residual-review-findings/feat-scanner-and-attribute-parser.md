# Residual Review Findings

Branch: `feat/scanner-and-attribute-parser`
Plan: `docs/plans/2026-08-09-001-feat-scanner-and-attribute-parser-plan.md`
Recorded: 2026-08-09

Findings from the code review of Phase 1 (Tasks 2 and 3) that were **not** applied
on this branch, with the evidence that produced them. Every one was reproduced by
execution against pandoc 3.10.1, per
`docs/solutions/conventions/execute-dont-read-when-reviewing-plans.md`.

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

## An unterminated quoted attribute value silently swallows the next field

**P1.** `split_fields` never checks whether `in_quote` is still true at the end of
the body, and `unquote` simply fails to match when there is no closing quote.
`attributes.parse('{title: "abc, class: tip}')` yields
`keyvals.title == '"abc, class: tip'` — the stray quote is kept literally and the
`class: tip` attribute vanishes with no error, even though `AGENTS.md` requires
unrecognized constructs to hard-error. For a blurb or aside, the `class:` that
controls rendering disappears silently.

**Why it was not applied.** The obvious fix — raise when `in_quote` is still true
at the end — also rejects input that parses correctly today. A value with a
literal quote in it, such as `{title: 5" pipe}`, currently yields `5" pipe` and
would begin aborting the build. Distinguishing "quote opens a quoted value" from
"quote is a literal character mid-value" needs a rule about where a quote may
appear, which is a Markua-spec decision rather than a mechanical fix. Rejecting
manuscripts that work today is worse than the current silent swallow, so this is
routed to the author rather than guessed at.

## Testing gaps

- No scanner coverage for code nested in a blockquote or a list item (the gaps
  above have no regression test either way).
- No attribute-parser test for an unterminated quoted value, or for duplicate
  keys in one attribute list (current behavior is last-wins, untested).
- No test composes `parse` into `to_pandoc_attr` for an escape-bearing value. The
  composition trap is now documented in `attributes.lua` but not pinned by a test,
  because the correct composed output depends on the unresolved unescape decision
  above.
- `to_pandoc_attr` emits `id` and each class unescaped, so an id or class
  containing a space or quote produces a syntactically broken attribute block.
  This **is** reachable straight from `parse`: `{#my id, .a class}` yields
  `id = "my id"` and a class of `a class`, which re-emit as `{#my id .a class}`.
  Uncovered, and it stays reachable until either the parser validates shortcut
  values or the writer escapes them — the same open question as the unterminated
  quote above, since both turn on which malformed input the parser may reject.

## Review context

Reviewers: correctness, project-standards, testing, maintainability, learnings,
adversarial. Applied on this branch: the table-driven fence patterns, the
`parse`/`to_pandoc_attr` composition note, the `class:` negative assertion, and
the trailing-record `number` and CRLF round-trip tests.

The cross-model adversarial peer pass did not run: no allowlisted peer route is
configured for this checkout, so the adversarial lens ran in-process. Its
agreement with the other reviewers is therefore same-model, not independent
cross-model corroboration.
