-- Luacheck configuration.
--
-- Without this, every file in the project reports false positives: the reader
-- and filters legitimately read and define globals that pandoc supplies, and
-- the specs use busted's DSL. CodeRabbit runs luacheck on pull requests, so an
-- unconfigured run would bury real findings under noise.

std = "lua54"

-- Pandoc's Lua is 5.4, and 120 is a more useful width than the default 80.
max_line_length = 120

-- The pure-Lua pipeline. These modules must NOT touch the pandoc global at all
-- -- busted runs under system Lua, where it does not exist. No pandoc globals
-- are declared here on purpose, so any reference is reported.
files["src/markua/*.lua"] = {}

-- The reader entry point defines Reader() and reads pandoc's globals.
files["src/markua.lua"] = {
  globals = { "Reader" },
  read_globals = { "pandoc", "PANDOC_SCRIPT_FILE", "PANDOC_STATE", "PANDOC_VERSION" },
}

-- Filters define element handlers named after AST node types.
files["src/filters/*.lua"] = {
  globals = {
    "Pandoc", "Meta", "Blocks", "Inlines",
    "Div", "Span", "Para", "Plain", "Header",
    "CodeBlock", "Code", "Image", "Link", "RawBlock", "RawInline",
  },
  read_globals = { "pandoc", "PANDOC_SCRIPT_FILE", "PANDOC_STATE", "PANDOC_VERSION" },
}

-- busted supplies the spec DSL.
files["test/*_spec.lua"] = {
  std = "lua54+busted",
}
