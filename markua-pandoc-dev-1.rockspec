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
  "busted",
}

-- Nothing to build: the reader is a pandoc script, not an installable module.
build = {
  type = "none",
}
