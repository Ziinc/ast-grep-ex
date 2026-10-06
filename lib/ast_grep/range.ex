defmodule AstGrep.Range do
  @moduledoc """
  A region of a source string, from `:start` (inclusive) to `:end`
  (exclusive).
  """

  alias AstGrep.Position

  defstruct [:start, :end]

  @type t :: %__MODULE__{start: Position.t(), end: Position.t()}
end
