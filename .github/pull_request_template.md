## What this changes

<!-- One or two sentences. Link the issue it closes. -->

Closes #

## How it was tested

<!-- Which specs, which golden cases. If you ran the whole-book smoke test, say
     against what manuscript and what the before/after failure counts were. -->

- [ ] `make test` passes locally

## Checklist

- [ ] New syntax support has both a unit test and a golden case
- [ ] No module under `src/markua/` references the `pandoc` global
- [ ] Every new transform is fence-aware (consumes `scanner.scan` output)
- [ ] Unknown constructs raise a `MarkuaError` with file and line, not a silent pass-through
- [ ] Regenerated golden files were read, not just accepted
- [ ] Commits are signed off (`git commit -s`)

## Anything deliberately left out

<!-- Scope you decided against, and why. Write "nothing" if that is the case. -->
