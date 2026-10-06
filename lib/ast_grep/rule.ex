defmodule AstGrep.Rule do
  @moduledoc """
  Information about a compiled rule, see `AstGrep.RuleSet.rules/1`.

    * `:id`, `:language` (normalized, e.g. `"elixir"`), `:severity`.
    * `:message` - the uninterpolated message (may contain `$A` etc.).
    * `:note`, `:url` - optional extra documentation.
    * `:fixable` - whether the rule has a `fix`.
    * `:files` / `:ignores` - the rule's glob lists, or `nil`. Each entry is a
      glob string or a map like `%{"glob" => "...", "caseInsensitive" => true}`.
    * `:metadata` - the rule's `metadata` map (string keys), or `nil`.
  """

  defstruct [
    :id,
    :language,
    :severity,
    :message,
    :note,
    :url,
    :fixable,
    :files,
    :ignores,
    :metadata
  ]

  @typedoc "Rule severity. Rules with severity `:off` are never compiled."
  @type severity :: :off | :hint | :info | :warning | :error

  @type glob :: String.t() | %{optional(String.t()) => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          language: String.t(),
          severity: severity(),
          message: String.t(),
          note: String.t() | nil,
          url: String.t() | nil,
          fixable: boolean(),
          files: [glob()] | nil,
          ignores: [glob()] | nil,
          metadata: %{optional(String.t()) => term()} | nil
        }
end
