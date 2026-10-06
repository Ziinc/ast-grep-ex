defmodule DemoApp.RulesTest do
  @moduledoc """
  Unit tests for the ast-grep rules of this project.

  This is the pattern to copy for your own rules: for each rule, scan a "bad"
  snippet and assert the exact matches (rule id, position, message, fix), and
  scan a "good" snippet and assert there are no matches.

  Each test runs a single rule (`AstGrep.RuleSet.filter/2`) so that rules
  don't interfere with each other's expectations.
  """
  use ExUnit.Case, async: true

  alias AstGrep.RuleSet

  @root Path.expand("..", __DIR__)

  # Every rule of rules/ (the `severity: off` rule is dropped when compiled).
  # Adding a rule without listing (and testing) it here fails the suite.
  @rule_ids ~w(
    bang-for-raising-functions
    nested-case
    no-console-log
    no-dbg
    no-io-inspect
    no-io-puts-in-lib
    prefer-direct-call
    prefer-enum-empty
    snake-case-atoms
  )

  setup_all do
    %{rule_set: RuleSet.from_config!(Path.join(@root, "sgconfig.yml"))}
  end

  # Scans `source` with the rule `id` only. `path` is relative to the project
  # root, as with `mix ast_grep.scan`: it selects the language and is matched
  # against the rule's `files`/`ignores` globs.
  defp scan(%{rule_set: rule_set}, id, source, path \\ "lib/demo_app/sample.ex") do
    rule_set = RuleSet.filter(rule_set, only: id)
    assert RuleSet.rule_ids(rule_set) == [id], "rule #{id} not found in rules/"
    AstGrep.scan!(source, rule_set, path: path)
  end

  defp summary(matches) do
    Enum.map(matches, &{&1.rule_id, &1.range.start.line, &1.range.start.column, &1.message})
  end

  defp fix(source, matches), do: AstGrep.apply_fixes(source, matches)

  test "rules/ holds exactly the tested rules", ctx do
    assert RuleSet.rule_ids(ctx.rule_set) == @rule_ids
  end

  test "severities, notes, urls and metadata are as documented", ctx do
    rules = Map.new(RuleSet.rules(ctx.rule_set), &{&1.id, &1})

    assert %{
             "no-dbg" => %{severity: :error},
             "no-io-inspect" => %{severity: :warning, fixable: true},
             "no-console-log" => %{severity: :warning, language: "javascript"},
             "bang-for-raising-functions" => %{severity: :warning},
             "no-io-puts-in-lib" => %{severity: :info},
             "prefer-direct-call" => %{severity: :info, fixable: true},
             "snake-case-atoms" => %{severity: :info, fixable: true},
             "nested-case" => %{severity: :hint},
             "prefer-enum-empty" => %{severity: :hint, fixable: true}
           } = rules

    assert rules["no-io-inspect"].url =~ "https://"
    assert rules["no-io-inspect"].note =~ "debugging"

    assert rules["bang-for-raising-functions"].metadata == %{"credo_category" => "design"}
    assert rules["prefer-direct-call"].metadata == %{"credo_category" => "refactor"}
    assert rules["snake-case-atoms"].metadata == %{"credo_category" => "consistency"}
    assert rules["prefer-enum-empty"].metadata == %{"credo_category" => "readability"}

    assert rules["nested-case"].metadata == %{
             "credo_category" => "refactor",
             "credo_priority" => "normal"
           }
  end

  describe "no-io-inspect (pattern + fix with a metavariable)" do
    test "flags IO.inspect/1 and fixes it to its argument", ctx do
      source = """
      def register(attrs) do
        user = IO.inspect(build_user(attrs))
        {:ok, user}
      end
      """

      matches = scan(ctx, "no-io-inspect", source)

      assert summary(matches) == [
               {"no-io-inspect", 2, 10, "Remove debugging call IO.inspect(build_user(attrs))"}
             ]

      assert fix(source, matches) == """
             def register(attrs) do
               user = build_user(attrs)
               {:ok, user}
             end
             """
    end

    test "does not flag other calls", ctx do
      assert scan(ctx, "no-io-inspect", ~s|Logger.info(inspect(user))|) == []
    end

    test "is ignored in test/** and scripts/**", ctx do
      source = "IO.inspect(user)"
      assert [_] = scan(ctx, "no-io-inspect", source, "lib/demo_app.ex")
      assert scan(ctx, "no-io-inspect", source, "test/demo_app_test.exs") == []
      assert scan(ctx, "no-io-inspect", source, "scripts/api_tour.exs") == []
    end
  end

  describe "no-dbg (global utility rule via matches:)" do
    test "flags dbg calls, with or without arguments", ctx do
      source = """
      user = dbg(user)
      user |> dbg()
      """

      assert summary(scan(ctx, "no-dbg", source)) == [
               {"no-dbg", 1, 8, "Remove dbg/1 before committing"},
               {"no-dbg", 2, 9, "Remove dbg/1 before committing"}
             ]
    end

    test "does not flag other calls", ctx do
      assert scan(ctx, "no-dbg", "debug(user)") == []
    end
  end

  describe "prefer-direct-call ($$$ multi-metavariable, constraints, transform)" do
    test "rewrites apply/3 with a literal function name to a direct call", ctx do
      source = """
      apply(DemoApp.Mailer, :deliver, [email, opts])
      apply(DemoApp.Clock, :now, [])
      """

      matches = scan(ctx, "prefer-direct-call", source)

      assert summary(matches) == [
               {"prefer-direct-call", 1, 1,
                "Call DemoApp.Mailer.deliver(...) directly instead of using apply/3"},
               {"prefer-direct-call", 2, 1,
                "Call DemoApp.Clock.now(...) directly instead of using apply/3"}
             ]

      assert fix(source, matches) == """
             DemoApp.Mailer.deliver(email, opts)
             DemoApp.Clock.now()
             """
    end

    test "does not flag a dynamic function name or argument list", ctx do
      source = """
      apply(module, fun, [arg])
      apply(DemoApp.Mailer, :deliver, args)
      """

      assert scan(ctx, "prefer-direct-call", source) == []
    end
  end

  describe "bang-for-raising-functions (has + stopBy: end, constraints regex)" do
    test "flags a function that raises but has no ! suffix", ctx do
      source = """
      def fetch_user(id) do
        case lookup(id) do
          nil -> raise "user not found"
          user -> user
        end
      end
      """

      assert summary(scan(ctx, "bang-for-raising-functions", source)) == [
               {"bang-for-raising-functions", 1, 1,
                "fetch_user/1 can raise: name it fetch_user! or return an error tuple"}
             ]
    end

    test "does not flag bang functions or functions that do not raise", ctx do
      source = """
      def fetch_user!(id) do
        lookup(id) || raise "user not found"
      end

      def fetch_user(id) do
        lookup(id) || {:error, :not_found}
      end
      """

      assert scan(ctx, "bang-for-raising-functions", source) == []
    end
  end

  describe "snake-case-atoms (kind + regex, transform convert/toCase in fix)" do
    test "flags camelCase atoms and fixes them to snake_case", ctx do
      source = "Map.get(params, :firstName)"
      matches = scan(ctx, "snake-case-atoms", source)

      assert summary(matches) == [
               {"snake-case-atoms", 1, 17, "Use :first_name instead of :firstName"}
             ]

      assert fix(source, matches) == "Map.get(params, :first_name)"
    end

    test "does not flag snake_case atoms", ctx do
      assert scan(ctx, "snake-case-atoms", "Map.get(params, :first_name)") == []
    end
  end

  describe "nested-case (inside + stopBy: end, not, kind)" do
    test "flags a case nested in another case", ctx do
      source = """
      case fetch(id) do
        {:ok, order} ->
          case order.status do
            :paid -> ship(order)
            _ -> :noop
          end

        error ->
          error
      end
      """

      assert summary(scan(ctx, "nested-case", source)) == [
               {"nested-case", 3, 5,
                "Nested case on order.status: consider `with` or a helper function"}
             ]
    end

    test "does not flag a case inside an anonymous function", ctx do
      source = """
      case fetch_all() do
        {:ok, orders} -> Enum.map(orders, fn o -> case o.status do :paid -> o end end)
        error -> error
      end
      """

      assert scan(ctx, "nested-case", source) == []
    end
  end

  describe "prefer-enum-empty (hint severity, fix)" do
    test "rewrites length(list) == 0", ctx do
      source = "if length(items) == 0, do: :empty"
      matches = scan(ctx, "prefer-enum-empty", source)

      assert summary(matches) == [
               {"prefer-enum-empty", 1, 4, "Use Enum.empty?(items) instead of length(items) == 0"}
             ]

      assert fix(source, matches) == "if Enum.empty?(items), do: :empty"
    end

    test "does not flag other comparisons", ctx do
      assert scan(ctx, "prefer-enum-empty", "length(items) == 1") == []
    end
  end

  describe "no-io-puts-in-lib (files / ignores globs)" do
    @source ~s|IO.puts("order shipped")|

    test "flags IO.puts in lib/", ctx do
      assert summary(scan(ctx, "no-io-puts-in-lib", @source, "lib/demo_app/orders.ex")) == [
               {"no-io-puts-in-lib", 1, 1, "Use Logger instead of IO.puts in library code"}
             ]
    end

    test "ignores lib/demo_app/cli.ex and files outside lib/", ctx do
      assert scan(ctx, "no-io-puts-in-lib", @source, "lib/demo_app/cli.ex") == []
      assert scan(ctx, "no-io-puts-in-lib", @source, "scripts/api_tour.exs") == []
      assert scan(ctx, "no-io-puts-in-lib", @source, "test/demo_app_test.exs") == []
    end
  end

  describe "no-console-log (JavaScript rule)" do
    test "flags console.log in JS files", ctx do
      source = """
      export function init() {
        console.log("booting", 1);
        console.error("kept");
      }
      """

      assert summary(scan(ctx, "no-console-log", source, "assets/js/app.js")) == [
               {"no-console-log", 2, 3, ~s|Remove console.log("booting", 1)|}
             ]
    end
  end

  describe "no-logger-debug (severity: off)" do
    @path Path.join(@root, "rules/no_logger_debug.yml")

    test "is disabled, and matches Logger.debug once enabled" do
      yaml = File.read!(@path)
      assert yaml =~ "severity: off"
      assert {:ok, %{rules: []}} = RuleSet.compile(yaml)

      enabled = RuleSet.compile!(String.replace(yaml, "severity: off", "severity: warning"))

      assert [%{rule_id: "no-logger-debug"}] =
               AstGrep.scan!(~s|Logger.debug("x")|, enabled, language: :elixir)
    end
  end

  describe "suppression comments" do
    test "`# ast-grep-ignore` suppresses every rule on the next line", ctx do
      source = """
      # ast-grep-ignore
      Map.get(params, :firstName)
      """

      assert scan(ctx, "snake-case-atoms", source) == []
    end

    test "`# ast-grep-ignore: rule-id` only suppresses that rule", ctx do
      source = """
      # ast-grep-ignore: snake-case-atoms
      Map.get(params, :firstName)
      # ast-grep-ignore: no-dbg
      Map.get(params, :lastName)
      """

      assert [{"snake-case-atoms", 4, 17, _}] = summary(scan(ctx, "snake-case-atoms", source))
    end
  end
end
