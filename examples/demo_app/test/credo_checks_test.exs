defmodule DemoApp.CredoChecksTest do
  @moduledoc """
  Tests for the per-rule Credo checks of credo_checks/, defined with
  `use AstGrep.Credo.Rule`, using Credo's own test helpers.
  """
  use Credo.Test.Case

  alias Credo.Priority
  alias DemoApp.Checks.{NoProcessSleep, NoStringToAtom}

  describe "DemoApp.Checks.NoStringToAtom (rule from a YAML file)" do
    test "wraps the rule of priv/ast_grep/checks/no_string_to_atom.yml" do
      assert %AstGrep.Rule{id: "no-string-to-atom", severity: :error} = NoStringToAtom.rule()
    end

    test "reports String.to_atom/1, with the category and priority from the rule" do
      """
      def role(params), do: String.to_atom(params["role"])
      """
      |> to_source_file("lib/demo_app/accounts.ex")
      |> run_check(NoStringToAtom)
      |> assert_issue(%{
        message: "String.to_atom/1 can exhaust the atom table: use String.to_existing_atom/1",
        trigger: ~s|String.to_atom(params["role"])|,
        line_no: 1,
        column: 23,
        category: :design,
        priority: Priority.to_integer(:higher)
      })
    end

    test "does not report String.to_existing_atom/1" do
      """
      def role(params), do: String.to_existing_atom(params["role"])
      """
      |> to_source_file("lib/demo_app/accounts.ex")
      |> run_check(NoStringToAtom)
      |> refute_issues()
    end
  end

  describe "DemoApp.Checks.NoProcessSleep (inline rule map)" do
    test "reports Process.sleep/1 with the module's category and base priority" do
      """
      def wait, do: Process.sleep(500)
      """
      |> to_source_file("lib/demo_app/orders.ex")
      |> run_check(NoProcessSleep)
      |> assert_issue(%{
        message: "Avoid Process.sleep(500): it blocks the caller",
        line_no: 1,
        column: 15,
        category: :refactor,
        priority: Priority.to_integer(:normal)
      })
    end

    test "honors the priority param set in .credo.exs" do
      "Process.sleep(1)"
      |> to_source_file("lib/demo_app/orders.ex")
      |> run_check(NoProcessSleep, priority: :low)
      |> assert_issue(%{priority: Priority.to_integer(:low)})
    end
  end
end
