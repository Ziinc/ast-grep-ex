defmodule DemoApp.Checks.NoStringToAtom do
  @moduledoc """
  A Credo check running a single ast-grep rule, read from a YAML file
  (relative to the project root). The module is recompiled when the file
  changes.
  """
  use AstGrep.Credo.Rule, file: "priv/ast_grep/checks/no_string_to_atom.yml"
end
