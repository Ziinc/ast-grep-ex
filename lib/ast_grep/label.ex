defmodule AstGrep.Label do
  @moduledoc """
  A highlighted region attached to a match.

  The `:primary` label covers the matched node. `:secondary` labels come from
  a rule's `labels` configuration (for example, labelling metavariables).
  """

  defstruct [:style, :message, :range]

  @type t :: %__MODULE__{
          style: :primary | :secondary,
          message: String.t() | nil,
          range: AstGrep.Range.t()
        }
end
