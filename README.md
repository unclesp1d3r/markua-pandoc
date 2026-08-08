# markua-pandoc

A [pandoc](https://pandoc.org) custom reader for [Markua](https://leanpub.com/markua/read) 0.30, so a Leanpub manuscript can be converted to DOCX, EPUB, LaTeX, ICML, or HTML in one command.

> **Status: early development.** The design and task breakdown are complete in [`docs/plan.md`](docs/plan.md); the reader itself is still being built. Nothing here is usable yet.

## Why

Leanpub writes Markua, and everyone else wants something else — a Word file for a copy editor, an ICML file for InDesign, an EPUB for review. Converting through markdown-to-markdown loses the things that matter most: index entries vanish, resource attributes get flattened, and blurbs become plain block quotes. A real reader keeps them, because the annotations survive all the way into the AST and can be turned into Word `XE` index fields and named paragraph styles on the way out.

## How it works

A **delegating reader**. Markua-only syntax is rewritten in pure Lua into pandoc-flavored markdown (fenced divs, bracketed spans, `$$` math), then handed to `pandoc.read` so pandoc's own parser handles everything CommonMark-shaped. A second layer of Lua filters turns the resulting AST annotations into output-format-specific constructs.

A from-scratch Markua parser is explicitly out of scope: it would mean reimplementing CommonMark in Lua. See [`AGENTS.md`](AGENTS.md) for the architecture and the constraints that follow from it.

## Requirements

- **pandoc 3.10+** — the custom reader API depends on it
- **Lua 5.4** — the version pandoc embeds, and therefore the one that actually runs the reader
- **[mise](https://mise.jdx.dev)** — pins both of the above, plus `just` and `shellcheck`

## Setup

```sh
mise install     # the pinned toolchain
just setup       # the above, plus busted (a luarocks package)
```

## Usage

Once the reader lands, conversion goes through the `bin/markua` wrapper, which resolves the reader and the standard filters and passes every other argument through to pandoc:

```sh
bin/markua chapter-01.md -o chapter-01.docx
bin/markua chapter-01.md -o chapter-01.epub --toc
bin/markua chapter-01.md -o chapter-01.docx --reference-doc=house-style.docx
```

## Scope

Targets Markua 0.30. Both real-world variants of the ambiguous syntax are supported: `{ix: "term"}` and `{i: "term"}` for index entries, and both the `{class: tip}` + `B>` form and the fenced `{blurb, class: tip}` … `{/blurb}` form for blurbs.

Out of scope for v1, by decision rather than oversight: quizzes and exercises (the Markua 0.10 course constructs, which are rejected with a clear error rather than silently dropped), smart crosslinks, `Book.txt` multi-file assembly, emoji shortcodes, and Leanpub document settings. The reasoning for each is at the end of [`docs/plan.md`](docs/plan.md).

## Development

```sh
just           # list every available recipe
just test      # everything CI runs
just unit      # busted specs only — fast, run these constantly
just lint      # every pre-commit hook, across all files
```

The project is test-driven: write the failing test, watch it fail, write the minimum to pass, commit. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full workflow and the four rules that are genuinely load-bearing.

## License

[Apache License 2.0](LICENSE).
