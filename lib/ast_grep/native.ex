defmodule AstGrep.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  # `force_build: true` in dev/test or with AST_GREP_BUILD=1, else unset so
  # that `config :rustler_precompiled, :force_build, ast_grep: true` applies.
  force_build_opts =
    AstGrep.Native.Build.force_build_opts(System.get_env("AST_GREP_BUILD"), Mix.env())

  rustler_opts =
    [
      otp_app: :ast_grep,
      crate: "ast_grep_nif",
      base_url: "https://github.com/Ziinc/ast-grep-ex/releases/download/v#{version}",
      version: version,
      nif_versions: ["2.15", "2.16", "2.17"],
      targets: ~w(
        aarch64-apple-darwin
        aarch64-unknown-linux-gnu
        aarch64-unknown-linux-musl
        x86_64-apple-darwin
        x86_64-pc-windows-gnu
        x86_64-pc-windows-msvc
        x86_64-unknown-linux-gnu
        x86_64-unknown-linux-musl
      )
    ] ++ force_build_opts

  use RustlerPrecompiled, rustler_opts

  def languages, do: err()
  def normalize_language(_lang), do: err()
  def language_for_path(_path), do: err()
  def compile_rules(_rules, _utils), do: err()
  def rules(_rule_set), do: err()
  def scan(_rule_set, _source, _lang, _path), do: err()
  def find_all(_rule_set, _source, _lang, _path), do: err()
  def dump_tree(_source, _lang), do: err()
  def parse_yaml(_yaml), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
