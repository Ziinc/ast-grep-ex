defmodule DemoApp.Checks.NoProcessSleep do
  @moduledoc """
  A Credo check running a single ast-grep rule given inline, as a map using
  ast-grep's keys (a YAML string or a keyword list work too).

  `:category` and `:base_priority` set the check's Credo category and
  priority, overriding the ones derived from the rule (`severity: warning`
  would be priority `high`).
  """
  use AstGrep.Credo.Rule,
    category: :refactor,
    base_priority: :normal,
    rule: %{
      id: "no-process-sleep",
      language: "elixir",
      severity: "warning",
      message: "Avoid Process.sleep($MS): it blocks the caller",
      note: "Use Process.send_after/3 or a timeout in receive instead.",
      rule: %{pattern: "Process.sleep($MS)"}
    }
end
