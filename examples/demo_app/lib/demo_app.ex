defmodule DemoApp do
  @moduledoc """
  A tiny shop used to showcase the `ast_grep` library.

  Its code intentionally breaks some of the rules of `rules/` and
  `priv/ast_grep/checks/`, see the README.
  """

  @doc "Returns the version of the app."
  def version, do: "0.1.0"
end
