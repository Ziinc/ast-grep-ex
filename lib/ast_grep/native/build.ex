defmodule AstGrep.Native.Build do
  @moduledoc false
  # Decides whether `AstGrep.Native` builds the NIF from source. Used at
  # compile time by `AstGrep.Native` (the compiler compiles this module first).

  @doc """
  The `:force_build` option given to `use RustlerPrecompiled`.

  A build is forced when `AST_GREP_BUILD` (`env_value`) is `"1"` or `"true"`,
  and in the `:dev` and `:test` environments of this project. Otherwise the
  option is left unset: RustlerPrecompiled then falls back to the
  `config :rustler_precompiled, :force_build, ast_grep: true` app config
  (an explicit option would take precedence over it).
  """
  @spec force_build_opts(String.t() | nil, atom()) :: keyword()
  def force_build_opts(env_value, mix_env) do
    if env_value in ["1", "true"] or mix_env in [:dev, :test],
      do: [force_build: true],
      else: []
  end
end
