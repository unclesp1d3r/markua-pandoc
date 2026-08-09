---
title: "Execute the code a plan ships, and verify what reviewers claim about it"
date: "2026-08-08"
category: "conventions"
module: "docs/plan.md review process"
problem_type: convention
component: development_workflow
severity: high
applies_when:
  - "Reviewing a plan, spec, or design doc that ships verbatim source or shell the implementer will paste in"
  - "Acting on findings from a code review, a subagent reviewer, or a cross-model peer"
  - "A reviewer reports a contradiction between two parts of a document and one side must be declared authoritative"
  - "A reviewer runs in an isolated sandbox without repository access"
tags:
  - "code-review"
  - "verification"
  - "plan-review"
  - "cross-model-review"
  - "false-positives"
  - "empirical-testing"
related_components:
  - documentation
  - testing_framework
---

# Execute the code a plan ships, and verify what reviewers claim about it

## Context

`docs/plan.md` is a TDD plan that ships **verbatim source** — complete Lua
modules and shell scripts the implementer is expected to paste in as-is. That
makes it an unusual review target: it reads like prose but behaves like code,
and a reader-only review grades the prose.

A multi-reviewer pass over it produced findings from five in-process reviewers
plus an independent cross-model reviewer. The findings split in a way that only
became visible once things were actually run.

## Guidance

**Run the code the document ships.** Extract every complete module and script
into a scratch directory and execute it against the project's pinned toolchain.
The plan's own fenced blocks are the test fixtures.

**Run the tool before accepting a finding that depends on tool behavior.** A
claim about how a downstream tool renders, parses, or names something is
checkable in under a minute. Check it.

**Treat sandboxed reviewers' repo-context claims as unverified.** A reviewer
running read-only in an empty scratch directory cannot see the repository, so
any finding of the form "X is not declared / not configured / missing" is
about *its* environment, not yours.

**When a reviewer reports a contradiction, do not auto-apply either side.** A
contradiction means two sources disagree; which one is authoritative is a
judgment call that belongs to the author.

## Why This Matters

Executing the plan's shipped code found two real defects that reading it did
not:

- `resources.transform` held a pending attribute line across a blank line and
  re-emitted it *after* the blank, silently merging a standalone
  `{ix: "term"}` index line into the following paragraph. The existing spec
  asserted only that the substring was still present, not where it landed, so
  the suite would have stayed green.
- `bin/markua` used `CDPATH= cd --`, which trips shellcheck's SC1007. `just lint`
  runs `pre-commit run --all-files`, whose shellcheck hook passes no severity
  threshold, so every severity surfaces — the very first commit of that file
  would have failed the project's own gate.

Running the tool refuted two findings that reading would have accepted:

- A reviewer reported that the callout filter emits `Callout Tip` while its
  test asserts `w:val="CalloutTip"`, and called it a guaranteed failure at
  maximum confidence. Building a DOCX with pandoc 3.10.1 showed the writer
  derives the styleId by stripping spaces — `Callout Tip` produces exactly
  `CalloutTip`. The filter and the test were both already correct. The reviewer
  had reasoned that the emitted style name must equal the styleId; that is a
  reading error, not an environment artifact. Notably, an in-process reviewer
  flagged the same thing but honestly recorded it as *unverifiable* rather than
  asserting it — the empirical check settled in seconds what neither reviewer
  could resolve by reading.
- A different reviewer reported the toolchain was "claimed pinned but not
  declared." The repository has `mise.toml` pinning `lua = "5.4.8"` and
  `pandoc = "3.10.1"`, with `mise.lock` beside it. That reviewer ran sandboxed
  from an empty directory with no repo access, and was describing its own
  environment rather than the project's.

Two false positives out of eighteen cross-model findings is not an alarming
rate on its own. What matters is that both were asserted at maximum confidence
and both would have caused an edit to correct code — and that they failed for
two unrelated reasons, one a reasoning error and one an environment artifact.
Neither is detectable by reading the finding. Both took under a minute to
settle by running something.

The contradiction case is the subtlest. Two reviewers agreed that a task's
documented attribute values disagreed with its code, and proposed **opposite**
fixes: one would correct the prose to match the code, the other correct the
code to match the prose. Either applied silently would have been defensible and
possibly wrong. It was routed to the author instead, who chose.

## When to Apply

- Any document that ships runnable content. If a reader is meant to paste it,
  a reviewer should be made to run it.
- Any finding whose truth depends on a tool's actual behavior — output naming,
  parsing, escaping, rendering. Cheap to check, expensive to get wrong.
- Any finding from a reviewer without repository access that asserts something
  about repository state.
- Any reported contradiction. Surface it as a decision; do not pick a side on
  the reviewer's behalf.

It is overkill for findings about a document's own prose — structure, clarity,
missing cross-references, internal inconsistency. Those are what reading is for,
and reading resolves them.

## Examples

**Extract and execute, in bulk.** Pull every complete module out of the fenced
blocks and syntax-check the lot against the pinned interpreter, then do the same
for shell:

```bash
# every full Lua module in the plan, checked against the pinned Lua
python3 - <<'EOF'
import re, subprocess, tempfile, os
s = open('docs/plan.md').read()
d = tempfile.mkdtemp()
for i, b in enumerate(re.findall(r'```lua\n(.*?)\n```', s, re.S)):
    if 'return M' not in b and 'function Reader' not in b:
        continue                      # skip fragments; only whole modules
    p = os.path.join(d, f'b{i}.lua'); open(p, 'w').write(b)
    r = subprocess.run(['mise','x','--','luac','-p',p], capture_output=True, text=True)
    print(('ok  ' if r.returncode == 0 else 'FAIL'), i, r.stderr.strip()[:80])
EOF
```

Syntax-checking is the floor, not the ceiling — behavioral tests against the
extracted modules are what found the reordering defect above.

**Refute a tool-behavior claim by running the tool.** The whole check:

```bash
printf '::: {custom-style="Callout Tip"}\nTip body.\n:::\n' > t.md
mise x -- pandoc -f markdown -t docx -o t.docx t.md
unzip -p t.docx word/document.xml | grep -o 'w:pStyle w:val="[^"]*"'
# -> w:pStyle w:val="CalloutTip"   (the space is stripped; the plan was right)
```

## Related

- `docs/solutions/architecture-patterns/ground-ast-shapes-in-pandoc-source.md`
  — the same principle applied to design decisions rather than review findings.
