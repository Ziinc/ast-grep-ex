defmodule AstGrep.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ast_grep,
    crate: "ast_grep_nif",
    base_url: "https://github.com/Ziinc/ast-grep-ex/releases/download/v#{version}",
    version: version,
    force_build: System.get_env("AST_GREP_BUILD") in ["1", "true"] or Mix.env() in [:dev, :test],
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
