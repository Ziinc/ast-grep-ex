import Config

# No precompiled ast_grep NIF has been published yet, so build it from source
# (requires Rust and a C compiler, plus `{:rustler, ...}` in deps).
# Alternatively, set the AST_GREP_BUILD=1 environment variable.
config :rustler_precompiled, :force_build, ast_grep: true
