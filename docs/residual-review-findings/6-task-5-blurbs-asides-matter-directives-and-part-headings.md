# Residual Review Findings — Task 5: Block constructs, directives, and part headings

Branch: `6-task-5-blurbs-asides-matter-directives-and-part-headings`
Plan: [`docs/plans/2026-08-16-001-feat-block-constructs-and-directives-plan.md`](../plans/2026-08-16-001-feat-block-constructs-and-directives-plan.md)

Two review rounds ran on this branch: a document review of the plan (five personas,
then two on the revision) and a code review of the diff (eight personas). Every
actionable P0/P1 from the code review was applied on this branch except the one
filed as an issue below. This file is the durable record for the rest.

Reviewers were in-process subagents sharing a model with the orchestrator. The
optional cross-model pass was **not** run — it would have sent repository code to a
third-party provider on an unattended run. Reviewer agreement here is therefore
weaker evidence than genuine cross-model corroboration would be, and that limit
applies to every finding below.

## Filed

- **P1 — a fenced code block inside a `B>`/`A>` run is invisible to the scanner.**
  `consume_prefixed_run` escapes `:::`/`$$` body lines with no fence-awareness,
  because `scanner.lua` never recognizes a ```` B> ``` ```` line as a fence opener —
  the prefix hides it. A code sample inside a blurb that contains a literal `:::`
  gets a stray backslash. Same class as two defects fixed on this branch, but the
  fix belongs in `scanner.lua` (teaching it `B>`/`A>` as container prefixes, the way
  it already handles blockquote `>`), which changes fence detection globally in a
  shipped module pinned by differential tests against pandoc.
  → [#22](https://github.com/unclesp1d3r/markua-pandoc/issues/22)
  *Source: adversarial reviewer, P1, verified by execution.*

## Carried forward

- **P2 — `open_div` re-implements what `attributes.to_pandoc_attr` already does.**
  It calls `attributes.check_name` three times and hand-rolls the check-then-concat
  sequence the canonical renderer already implements. Consolidating means building a
  synthetic parsed table and reusing `to_pandoc_attr`. Not applied because it touches
  the exact function the P0/P1 fixes were landing in; doing both at once would have
  made the corruption fixes harder to review.
  *Source: maintainability reviewer, P2.*

- **The byte-identity claim still has no enforcement.** `docs/plan.md` embeds
  `blocks.lua`, `blocks_spec.lua`, `attributes.lua`, `config.lua`, and both their
  specs verbatim, and nothing in CI checks it. This branch re-synced those embeds
  three separate times — after implementation, after simplification, and after the
  review fixes — each verified by hand with an extract-and-diff. The Task 4 residual
  record already noted this broke once before, caught only by hand. A ~20-line
  extraction script wired into `just test` would turn it into a real gate; it is
  still unbuilt, and the cost of not building it went up this branch.
  *Source: adversarial and maintainability reviewers, residual risk. Previously recorded on the Task 4 branch.*

- **The DocBook head-class property is applied, not re-verified here.** The callout
  class must head the emitted class list because pandoc's DocBook writer matches only
  the first class; reversed order degrades a real `<tip>` to a bare `<para>` with no
  error. That was verified and recorded in
  `docs/solutions/architecture-patterns/ground-ast-shapes-in-pandoc-source.md`. This
  branch's spec asserts only on the emitted markdown string — and **cannot** do more,
  since busted runs under system Lua where the `pandoc` global does not exist. An
  ad-hoc check during this work confirmed the property still holds through the real
  writer, but nothing in the suite pins it. The golden-file and filter harnesses
  (Tasks 9 and 11) are where that belongs.
  *Source: learnings researcher, correcting an overstatement in the orchestrator's own framing.*

- **`{class: tip, weird}` routes to the unrecognized-directive error.** The
  bare-word branch is gated on `#parsed.bare == 1`, so an attribute list carrying
  both a class and a stray bare word reports as an unrecognized directive rather than
  as a list with an unrecognized attribute. No requirement documents what should
  happen here, so this is an undefined-behavior note rather than a defect.
  *Source: correctness reviewer, residual risk.*

- **Non-`id` keyvals on a consumed pending list are discarded.** The blurb and aside
  paths thread `id` and classes onto the div but drop any other key. Whether Markua
  0.30 defines any such key as legal on a blurb or aside opener was not confirmed, so
  no finding was filed.
  *Source: project-standards reviewer, residual risk.*

## Testing gaps

None of these block the branch; all are places the suite would not catch a
regression.

- `attributes.render_value` is reachable for the first time through the
  heading-attach path, and no scenario exercises a keyval value carrying an embedded
  quote or brace through it. *(security)*
- No scenario covers a directive-shaped list with extra content, e.g.
  `{pagebreak extra}`. *(reliability)*
- `config.is_index_key` is covered for both accepted keys and the `index` prefix
  collision, but not for a wholly unrelated key. *(testing)*
- No scenario combines an `id` with a decorative class in one call, or exercises a
  decorative class on either fenced form. *(testing, maintainability)*

## Not captured as a learning

The learnings researcher evaluated three candidates and recommended writing **none**
of them:

- The class-order property and the whole-attribute-block-rejection failure mode are
  both already covered by existing entries
  (`ground-ast-shapes-in-pandoc-source.md`, `match-the-readers-exact-target-dialect.md`),
  and this branch applied them correctly rather than rediscovering them.
- The third candidate — that Markua's attribute grammar makes class *provenance*
  tracking unnecessary — is real but was judged borderline: its framing needs a
  caveat (`attributes.lua`'s parser does accept `.class`/`#id` shorthand that Markua
  authors never write), and the supporting story could not be verified from git
  history because the wrong approach was corrected during planning, before any
  commit. The recommendation was to wait for recurrence — if Task 7's `resources.lua`
  independently re-derives the same answer, that is the signal it generalizes.
