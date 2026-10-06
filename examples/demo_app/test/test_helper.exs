# The per-rule Credo checks live in credo_checks/ (loaded by `.credo.exs` via
# `requires:`), not in lib/, so they are not part of the app. Load them here
# so they can be tested.
for file <- Path.wildcard("credo_checks/**/*.ex"), do: Code.require_file(file)

ExUnit.start()
