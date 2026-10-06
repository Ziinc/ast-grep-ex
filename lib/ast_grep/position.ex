defmodule AstGrep.Position do
  @moduledoc """
  A position in a source string.

    * `:line` - 1-based line number.
    * `:column` - 1-based column, counted in characters (not bytes).
    * `:offset` - 0-based byte offset into the source, suitable for
      `binary_part/3`.
  """

  defstruct [:line, :column, :offset]

  @type t :: %__MODULE__{
          line: pos_integer(),
          column: pos_integer(),
          offset: non_neg_integer()
        }
end
