# Task runner for markua-pandoc. See docs/plan.md for the full design.
#
# Recipes are introduced alongside the scripts they call, so `just test` never
# invokes something that does not exist yet. `golden`, `filters` and `cli` are
# added by Tasks 9, 10 and 12.

# List the available recipes.
default:
    @just --list

# Everything CI runs.
test: unit

# busted unit specs. Fast; run these constantly.
unit:
    busted test/

# Install dev dependencies (busted is a luarocks package, not a mise tool).
install:
    luarocks install --local busted

# Full setup from a clean checkout: mise owns the toolchain, luarocks owns busted.
setup:
    mise install
    @just install

# Every pre-commit hook, across all files rather than just the staged ones.
lint:
    pre-commit run --all-files

clean:
    rm -rf build
