defmodule AstGrep.Fix do
  @moduledoc """
  An auto-fix produced by a rule's `fix` for a single match.

    * `:title` - optional fix title (from a fix config with `title`).
    * `:replacement` - the text, with metavariables substituted, that replaces
      the region described by `:range`.
    * `:range` - the region of the original source being replaced. This can
      be larger than the match range when the fix uses `expandStart` /
      `expandEnd`.

  See `AstGrep.apply_fixes/2`.
  """

  defstruct [:title, :replacement, :range]

  @type t :: %__MODULE__{
          title: String.t() | nil,
          replacement: String.t(),
          range: AstGrep.Range.t()
        }
end
