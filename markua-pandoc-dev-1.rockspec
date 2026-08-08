package = "markua-pandoc"
version = "dev-1"

source = {
  url = "git+https://github.com/unclesp1d3r/markua-pandoc.git",
}

description = {
  summary  = "A pandoc custom reader for Markua 0.30",
  homepage = "https://github.com/unclesp1d3r/markua-pandoc",
  license  = "Apache-2.0",
}

-- Development dependencies only. lua itself comes from mise, not luarocks, but
-- declaring the floor keeps `luarocks install --only-deps` honest about it.
dependencies = {
  "lua >= 5.4",
  -- Pinned to floors rather than left open: an unconstrained dependency lets a
  -- clean CI run resolve a newer release than any commit chose.
  "busted >= 2.2, < 3.0",
  "luacheck >= 1.2, < 2.0",
}

-- Nothing to build: the reader is a pandoc script, not an installable module.
build = {
  type = "none",
}
