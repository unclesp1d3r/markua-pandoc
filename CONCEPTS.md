# Concepts

Shared domain vocabulary for this project — entities, named processes, and status
concepts with project-specific meaning. Seeded with core domain vocabulary, then
accretes as ce-compound and ce-compound-refresh process learnings; direct edits are
fine. Glossary only, not a spec or catch-all.

> Seeded before the source tree existed, from the declared domain model in the
> implementation plan. These entries describe intended design rather than verified
> behavior — refresh them against the code as modules land.

## Relationships

A **Markua** document is read by the **delegating reader**, which rewrites only the
Markua-specific constructs — **attribute lists**, **blurbs**, **asides**, **matter
directives**, **index entries**, **resources** — into pandoc-flavored markdown and
hands the rest to pandoc's own parser. Every one of those rewrites is subject to
**fence-awareness**. Constructs the rewrite cannot carry through markdown survive as
AST annotations, which **filters** then turn into output-format-specific
constructs. **Golden files** pin the reader's output; filter behavior is asserted
against real generated documents instead.

## The format

### Markua

The markdown variant Leanpub uses for book manuscripts — CommonMark-shaped, with a
brace-delimited attribute syntax and a set of book-specific block constructs layered
on top. The project targets the 0.30 line; the course constructs from the older 0.10
line (quizzes, exercises) are out of scope and are rejected with a clear error rather
than silently dropped.

### Attribute list

A brace-delimited line carrying keys, an id, or classes that configure the construct
it attaches to. It is the syntactic substrate most block-level Markua constructs are
built from — though not all of them; some are recognized by a line prefix instead and
never carry an attribute list. An unrecognized attribute list is a hard error naming
file and line rather than something passed through as literal braces, because silently
emitting braces into a manuscript is worse than failing. See Strict mode.

### Blurb

A callout block — the construct an author uses for a tip, a warning, or a note. Two
syntaxes are both valid and both must work: a class-bearing attribute list above a run
of marker-prefixed lines (the spec form), and an explicitly fenced open/close pair
(the form Leanpub also accepts).

The set of classes a blurb may carry is configurable rather than fixed. A documented
default ships, but real Leanpub builds reject some of it and individual books narrow
the set further, so the list is config-overridable by design.

### Aside

A sibling block construct to a Blurb, distinguished by its semantic role in the book
rather than by its content. It shares the Blurb's configurable-class treatment, and,
like a Blurb, is specified with two input syntaxes: a line prefix, and an explicitly
fenced open/close pair.

### Matter directive

A marker separating a manuscript's front matter, main matter, and back matter. It
partitions the document rather than wrapping content, so it has no closing form. This
project's plans also call it a structural directive — the two names refer to the same
construct.

### Insertion directive

A marker that positions generated or metadata content — a back-of-book index, a table
of contents, a list of figures — rather than partitioning the book the way a Matter
directive does. Like a Matter directive, it is a marker with no closing form; unlike a
Matter directive, what it names is never produced by the reader itself, only marked as
a place something else must be produced.

### Index entry

An inline marker naming a term for the book's index. Two syntaxes are accepted: the
Markua spec form, which is canonical, and a widespread real-world abbreviation that
manuscripts use interchangeably. Both support hierarchy — a separator inside the term
nests a subentry under a parent entry.

Index entries are the clearest case for why this project exists: a
markdown-to-markdown pipeline drops them, because markdown has nowhere to put them.

### Resource

An included external file — figure, table, code listing, or embedded document.
Resources share one syntax and are dispatched on the file extension, so the extension,
not the author, decides which kind of output construct is produced.

### Strict mode

The default posture toward constructs the reader does not recognize: abort, naming the
offending file and line. Lenient mode is the opt-in downgrade that turns those aborts
into warnings and lets the conversion finish.

The strict default exists because the failure it prevents is silent — an unrecognized
construct that survives into the output becomes literal brace punctuation in a
finished book. Lenient mode is for triaging an unfamiliar manuscript, not for
production conversions.

## The pipeline

### Delegating reader

The project's central architectural choice: rather than parse Markua from scratch,
rewrite only the Markua-specific syntax into pandoc-flavored markdown and delegate all
CommonMark-shaped work to pandoc's own parser. A from-scratch native parser is
explicitly out of scope, because it would mean reimplementing CommonMark.

The rewrite layer is pure — it does not depend on the pandoc runtime — so it stays
unit-testable under a plain Lua interpreter. Only the entry point and the filters
touch pandoc itself. This boundary is the project's most load-bearing structural rule:
crossing it makes a module untestable.

### Fence-awareness

The invariant that no transform may treat content inside a fenced code block as
Markua. It is mandatory in every transform rather than optional, because real
manuscripts contain code blocks whose lines legitimately open with a brace, and a
naive attribute-list match corrupts them.

Fence tracking is owned by a single stage; every other stage consumes that stage's
classified output rather than re-scanning raw text.

### Filter

A post-parse transform that turns an AST annotation the reader left behind into an
output-format-specific construct. Filters exist for the constructs markdown cannot
carry through the delegation step — index entries, callout styling, and the resource
kinds that have no markdown representation — and are the second half of what makes a
markdown-to-markdown pipeline insufficient.

A construct usually needs one filter per output family rather than one filter overall,
because what a target format can express varies: some formats have a native construct,
some need a raw escape hatch, and some already carry the annotation's attributes
through without help, needing no filter at all.

### Golden file

A recorded pandoc AST for a given input, checked in beside that input and compared
against on every run. Golden files are regenerated deliberately rather than
automatically, because a golden file generated from broken code silently locks the bug
in as expected behavior — regenerated output is read before it is committed.

### Round-trip check

A verification that converts a document to a target format, reads it back with pandoc's
own reader for that format, and asserts the original annotation is recovered unchanged.

It is a stronger guarantee than asserting on the generated output directly: a search for
an expected marker in generated output passes even when the marker carries the wrong
content, whereas a round trip only passes when the meaning survives. A round-trip check
is available only where pandoc can both write and read the format, which is why it
supplements rather than replaces Golden files.

## Flagged ambiguities

- Two index syntaxes are in real-world use and both are accepted, but the spec form is
  canonical — prefer it when writing new content or examples.
- "Blurb" is used for the construct regardless of which of its two syntaxes appears;
  the fenced form is not a separate concept.
