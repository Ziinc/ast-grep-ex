# Releasing

`ast_grep` ships precompiled NIFs through
[RustlerPrecompiled](https://hexdocs.pm/rustler_precompiled). The
"Build precompiled NIFs" workflow (`.github/workflows/release.yml`) builds
8 targets x 3 NIF versions (2.15, 2.16, 2.17) and attaches the tarballs to
the GitHub release for the pushed tag.

## Steps

1. Bump the version in both places and commit:
   - `mix.exs`: `@version "X.Y.Z"`
   - `native/ast_grep_nif/Cargo.toml`: `version = "X.Y.Z"` (then run
     `cargo check` in `native/ast_grep_nif` to refresh `Cargo.lock`)

2. Tag and push. The tag must be `v` + the `mix.exs` version, otherwise the
   workflow fails:

   ```sh
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

3. Wait for the "Build precompiled NIFs" workflow to finish for the tag. All
   24 jobs must succeed, and the GitHub release `vX.Y.Z` must list all 24
   `*ast_grep_nif-vX.Y.Z-nif-*.tar.gz` assets. If a job flakes, re-run it.
   You can also start the workflow by hand ("Run workflow" on the tag ref).
   Assets are only uploaded when the run is for a tag.

4. Generate the checksum file from the published assets:

   ```sh
   AST_GREP_BUILD=1 mix rustler_precompiled.download AstGrep.Native --all --print
   ```

   This writes `checksum-Elixir.AstGrep.Native.exs` at the repo root. Commit
   it. The file is part of the Hex package (`checksum-*.exs` in `mix.exs`).

5. Publish to Hex:

   ```sh
   mix hex.publish
   ```

## Before the first release (no checksum file yet)

RustlerPrecompiled will not download NIFs without a checksum file. Until a
release ships `checksum-Elixir.AstGrep.Native.exs`, consumers have to build
the NIF from source. They set `AST_GREP_BUILD=1` (or `true`), and they need
a Rust toolchain (1.91+) plus a C/C++ compiler for the tree-sitter grammars.
In this repo, the `:dev` and `:test` environments always build from source.
