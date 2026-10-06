defmodule AstGrep.Credo.RuleTest.NoIoInspect do
  use AstGrep.Credo.Rule, file: "test/fixtures/credo/rules/no_io_inspect.yml"
end

defmodule AstGrep.Credo.RuleTest.NoDbg do
  use AstGrep.Credo.Rule,
    rule: """
    id: no-dbg
    language: elixir
    severity: error
    message: Remove dbg($$$ARGS)
    rule:
      pattern: dbg($$$ARGS)
    """
end

defmodule AstGrep.Credo.RuleTest.NoApply do
  use AstGrep.Credo.Rule,
    id: "AG001",
    category: :refactor,
    base_priority: :low,
    rule: %{
      id: "no-apply",
      language: "elixir",
      severity: "info",
      message: "Avoid apply/3",
      rule: %{pattern: "apply($M, $F, $A)"}
    }
end

defmodule AstGrep.Credo.RuleTest.NoDbgViaConfig do
  use AstGrep.Credo.Rule,
    config: "test/fixtures/credo/sgconfig.yml",
    rule: [
      id: "no-dbg-via-config",
      language: :elixir,
      message: "No dbg",
      rule: [matches: "dbg-call"]
    ]
end

defmodule AstGrep.Credo.RuleTest.NoDbgViaUtils do
  use AstGrep.Credo.Rule,
    file: "test/fixtures/credo/extra/uses_util.yml",
    utils: ["test/fixtures/credo/utils"]
end

defmodule AstGrep.Credo.RuleTest.NoApplyInLib do
  use AstGrep.Credo.Rule,
    file: "test/fixtures/credo/rules/no_apply_in_lib.yml",
    config: "test/fixtures/credo/sgconfig.yml"
end

defmodule AstGrep.Credo.RuleTest.NoStringToAtom do
  use AstGrep.Credo.Rule, file: "test/fixtures/credo/extra/no_string_to_atom.yml"
end

defmodule AstGrep.Credo.RuleTest do
  use Credo.Test.Case

  alias AstGrep.Credo.RuleTest.{
    NoApply,
    NoApplyInLib,
    NoDbg,
    NoDbgViaConfig,
    NoDbgViaUtils,
    NoIoInspect,
    NoStringToAtom
  }

  alias Credo.Priority

  @root Path.expand("../../fixtures/credo", __DIR__)

  @source """
  defmodule Sample do
    def run(user) do
      IO.inspect(user)
      dbg(user)
      apply(Sample, :other, [user])
      # ast-grep-ignore
      IO.inspect(:suppressed)
      String.to_atom(user.name)
    end
  end
  """

  defp source_file(filename \\ "lib/sample.ex"), do: to_source_file(@source, filename)

  describe "file:" do
    test "defines a check reporting the rule's matches" do
      source_file()
      |> run_check(NoIoInspect)
      |> assert_issue(%{
        check: NoIoInspect,
        message: "Remove IO.inspect(user)",
        trigger: "IO.inspect(user)",
        line_no: 3,
        column: 5,
        category: :warning,
        exit_status: 16,
        priority: Priority.to_integer(:high)
      })
    end

    test "derives the check's attributes from the rule" do
      assert NoIoInspect.category() == :warning
      assert NoIoInspect.base_priority() == :high
      assert NoIoInspect.docs_uri() == "https://example.com/rules/no-io-inspect"
      assert NoIoInspect.id() == "AstGrep.Credo.RuleTest.NoIoInspect"
      assert %AstGrep.Rule{id: "no-io-inspect", severity: :warning} = NoIoInspect.rule()
    end

    test "builds the explanation from the rule's message, note and url" do
      explanation = NoIoInspect.explanations()[:check]

      assert explanation =~ "Remove IO.inspect($A)"
      assert explanation =~ "IO.inspect/1 calls are usually debugging leftovers."
      assert explanation =~ "See: https://example.com/rules/no-io-inspect"
      assert explanation =~ "`no-io-inspect`"
      assert explanation =~ "severity: warning"
      assert explanation =~ "fixable"
      assert explanation =~ "test/fixtures/credo/rules/no_io_inspect.yml"
    end

    test "uses metadata.credo_category and credo_priority" do
      assert NoStringToAtom.category() == :design
      assert NoStringToAtom.base_priority() == :normal

      source_file()
      |> run_check(NoStringToAtom)
      |> assert_issue(%{
        category: :design,
        exit_status: 2,
        priority: Priority.to_integer(:normal)
      })
    end
  end

  describe "rule:" do
    test "accepts inline YAML" do
      assert NoDbg.base_priority() == :higher
      assert NoDbg.explanations()[:check] =~ "inline rule"

      source_file()
      |> run_check(NoDbg)
      |> assert_issue(%{
        message: "Remove dbg(user)",
        line_no: 4,
        priority: Priority.to_integer(:higher)
      })
    end

    test "accepts maps, with check options" do
      assert NoApply.id() == "AG001"
      assert NoApply.category() == :refactor
      assert NoApply.base_priority() == :low

      source_file()
      |> run_check(NoApply)
      |> assert_issue(%{
        message: "Avoid apply/3",
        line_no: 5,
        category: :refactor,
        exit_status: 8,
        priority: Priority.to_integer(:low)
      })
    end

    test "accepts keyword lists, with utils from a config" do
      source_file()
      |> run_check(NoDbgViaConfig)
      |> assert_issue(%{message: "No dbg", line_no: 4})
    end
  end

  test "utils: loads utility rules" do
    source_file()
    |> run_check(NoDbgViaUtils)
    |> assert_issue(%{message: "Remove dbg calls", line_no: 4})
  end

  test "each check reports only its own rule" do
    for {check, line} <- [{NoIoInspect, 3}, {NoDbg, 4}, {NoApply, 5}, {NoStringToAtom, 8}] do
      source_file()
      |> run_check(check)
      |> assert_issue(%{check: check, line_no: line})
    end
  end

  test "check params override the category and priority" do
    source_file()
    |> run_check(NoIoInspect, category: :readability, priority: :low)
    |> assert_issue(%{
      category: :readability,
      exit_status: 4,
      priority: Priority.to_integer(:low)
    })
  end

  test "files/ignores globs are relative to the config's directory" do
    file = fn relative ->
      source_file = source_file()
      %{source_file | filename: Path.join(@root, relative)}
    end

    [file.("lib/sample.ex")] |> run_check(NoApplyInLib) |> assert_issue(%{line_no: 5})
    [file.("lib/generated/sample.ex")] |> run_check(NoApplyInLib) |> refute_issues()
    [file.("test/sample_test.exs")] |> run_check(NoApplyInLib) |> refute_issues()
  end

  test "run/2 works without run_on_all_source_files/3" do
    source_file() |> NoDbg.run([]) |> assert_issue(%{line_no: 4})
  end

  test "caches the compiled rule set" do
    source_file() |> run_check(NoDbg)
    %{hash: hash} = NoDbg.__ast_grep_source__()

    assert %AstGrep.RuleSet{} = :persistent_term.get({AstGrep.Credo.Rule, NoDbg, hash})
  end

  test "registers the rule files as external resources" do
    resources =
      NoApplyInLib.__info__(:attributes)
      |> Keyword.get_values(:external_resource)
      |> List.flatten()

    assert "test/fixtures/credo/rules/no_apply_in_lib.yml" in resources
    assert "test/fixtures/credo/sgconfig.yml" in resources
    assert "test/fixtures/credo/utils/dbg_call.yml" in resources
  end

  describe "compile errors" do
    defp define(opts) do
      module = Module.concat(__MODULE__, "Check#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use AstGrep.Credo.Rule, unquote(opts)
          end
        end
      )
    end

    test "a file with several rules" do
      assert_raise CompileError,
                   ~r/must define exactly one rule, found 2: first-rule, second-rule/,
                   fn ->
                     define(file: "test/fixtures/credo/extra/two_rules.yml")
                   end
    end

    test "no rule" do
      assert_raise CompileError, ~r/found none/, fn ->
        define(rule: "id: off\nlanguage: elixir\nseverity: off\nrule:\n  pattern: foo\n")
      end
    end

    test "missing or conflicting options" do
      assert_raise CompileError, ~r/requires a :file or a :rule option/, fn -> define([]) end

      assert_raise CompileError, ~r/either :file or :rule/, fn ->
        define(file: "test/fixtures/credo/rules/no_dbg.yml", rule: "id: x")
      end

      assert_raise ArgumentError, ~r/unknown options for AstGrep.Credo.Rule: \[:pattern\]/, fn ->
        define(pattern: "foo")
      end
    end

    test "invalid rules" do
      assert_raise CompileError, ~r/missing\.yml: no such file/, fn ->
        define(file: "test/fixtures/credo/rules/missing.yml")
      end

      assert_raise CompileError, ~r/cobol/, fn ->
        define(file: "test/fixtures/credo/invalid/unknown_language.yml")
      end

      # `matches: dbg-call` needs utils.
      assert_raise CompileError, ~r/dbg-call/, fn ->
        define(file: "test/fixtures/credo/rules/no_dbg.yml")
      end

      assert_raise CompileError, ~r/invalid metadata.credo_category "style"/, fn ->
        define(file: "test/fixtures/credo/invalid/bad_category.yml")
      end

      assert_raise CompileError, ~r/invalid category :style/, fn ->
        define(file: "test/fixtures/credo/rules/no_io_inspect.yml", category: :style)
      end
    end
  end
end
