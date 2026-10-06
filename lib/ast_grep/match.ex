defmodule AstGrep.Match do
  @moduledoc """
  A node matched by a rule.

    * `:rule_id` - id of the rule that matched (`"find"` for `AstGrep.find/3`).
    * `:language` - normalized language name, e.g. `"elixir"`.
    * `:severity` - the rule's severity.
    * `:message` - the rule's message with metavariables interpolated.
    * `:note` / `:url` - the rule's note and documentation url.
    * `:text` - the matched source text.
    * `:kind` - the tree-sitter kind of the matched node, e.g. `"call"`.
    * `:range` - where the match is in the source.
    * `:meta_variables` - captured metavariables keyed by name without the
      `$` prefix: `$A` gives `"A" => "text"` and `$$$ARGS` gives
      `"ARGS" => ["a", "b"]` (the named nodes captured).
    * `:labels` - highlighted regions, see `AstGrep.Label`.
    * `:fix` - the fix for this match when the rule has a `fix`, else `nil`.
  """

  defstruct [
    :rule_id,
    :language,
    :severity,
    :message,
    :note,
    :url,
    :text,
    :kind,
    :range,
    :meta_variables,
    :labels,
    :fix
  ]

  @type t :: %__MODULE__{
          rule_id: String.t(),
          language: String.t(),
          severity: AstGrep.Rule.severity(),
          message: String.t(),
          note: String.t() | nil,
          url: String.t() | nil,
          text: String.t(),
          kind: String.t(),
          range: AstGrep.Range.t(),
          meta_variables: %{optional(String.t()) => String.t() | [String.t()]},
          labels: [AstGrep.Label.t()],
          fix: AstGrep.Fix.t() | nil
        }
end
