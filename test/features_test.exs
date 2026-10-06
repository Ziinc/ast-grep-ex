# Per-rule Credo checks for the "One Credo check per rule" section of the
# README, compiled from the README-shaped fixture project
# (test/fixtures/readme). `:file` and `:config` paths are relative to the
# project root, the current directory at compile time.

defmodule AstGrep.FeaturesTest.NoStringToAtom do
  use AstGrep.Credo.Rule, file: "test/fixtures/readme/priv/ast_grep/rules/no_string_to_atom.yml"
end

defmodule AstGrep.FeaturesTest.NoIoInspect do
  use AstGrep.Credo.Rule,
    file: "test/fixtures/readme/rules/no_io_inspect.yml",
    config: "test/fixtures/readme/sgconfig.yml"
end

defmodule AstGrep.FeaturesTest.InlineYaml do
  use AstGrep.Credo.Rule,
    rule: """
    id: inline-yaml
    language: elixir
    severity: error
    message: Remove dbg($$$ARGS)
    rule:
      pattern: dbg($$$ARGS)
    """
end

defmodule AstGrep.FeaturesTest.InlineMap do
  use AstGrep.Credo.Rule,
    rule: %{
      id: "inline-map",
      language: "elixir",
      severity: "warning",
      message: "Avoid String.to_atom($A)",
      rule: %{pattern: "String.to_atom($A)"}
    }
end

defmodule AstGrep.FeaturesTest.InlineKeyword do
  use AstGrep.Credo.Rule,
    id: "AG001",
    category: :refactor,
    base_priority: :low,
    rule: [
      id: "inline-keyword",
      language: :elixir,
      severity: :error,
      message: "Avoid String.to_atom/1",
      rule: [pattern: "String.to_atom($A)"]
    ]
end

defmodule AstGrep.FeaturesTest.WithUtils do
  use AstGrep.Credo.Rule,
    utils: ["test/fixtures/readme/utils"],
    rule: [
      id: "with-utils",
      language: :elixir,
      message: "dbg via :utils",
      rule: [matches: "dbg-call"]
    ]
end

defmodule AstGrep.FeaturesTest.WithConfig do
  use AstGrep.Credo.Rule,
    config: "test/fixtures/readme/sgconfig.yml",
    rule: [
      id: "with-config",
      language: :elixir,
      message: "dbg via :config",
      rule: [matches: "dbg-call"]
    ]
end

defmodule AstGrep.FeaturesTest do
  @moduledoc """
  Acceptance spec of the features claimed in README.md: one `describe` per
  README section, using only the public API.

  The fixture project test/fixtures/readme follows the README's layout
  (`sgconfig.yml`, `rules/`, `utils/`, `priv/ast_grep/rules/`), its
  `rules/no_io_inspect.yml` being the README's example rule.
  """

  # Changes the current directory and the Mix shell.
  use Credo.Test.Case, async: false

  alias AstGrep.{Match, Position, Rule, RuleSet}
  alias AstGrep.Credo.Check
  alias Credo.Priority

  alias AstGrep.FeaturesTest.{
    InlineKeyword,
    InlineMap,
    InlineYaml,
    NoIoInspect,
    NoStringToAtom,
    WithConfig,
    WithUtils
  }

  @moduletag :tmp_dir

  @fixture Path.expand("fixtures/readme", __DIR__)
  @config Path.join(@fixture, "sgconfig.yml")

  # A copy of the fixture project in the test's tmp dir.
  defp project(%{tmp_dir: dir}) do
    File.cp_r!(@fixture, dir)
    dir
  end

  defp lib_source, do: File.read!(Path.join(@fixture, "lib/my_app.ex"))

  # A Credo source file of lib/my_app.ex, named `filename`.
  defp source_file(filename \\ Path.join(@fixture, "lib/my_app.ex")),
    do: to_source_file(lib_source(), filename)

  defp summary(issues) do
    issues
    |> Enum.sort_by(&{&1.line_no, &1.message})
    |> Enum.map(&{&1.line_no, &1.message})
  end

  describe "README: introduction" do
    test "searches and rewrites code with patterns such as IO.inspect($A)" do
      assert {:ok, [%Match{text: "IO.inspect(user)", meta_variables: %{"A" => "user"}}]} =
               AstGrep.find("x = IO.inspect(user)", "IO.inspect($A)", language: :elixir)

      assert AstGrep.replace("x = IO.inspect(user)", "IO.inspect($A)", "$A", language: :elixir) ==
               {:ok, "x = user"}
    end

    test "supports ast-grep's built-in languages" do
      samples = [
        {:elixir, "IO.inspect(x)", "IO.inspect($A)", "IO.inspect(x)"},
        {:javascript, "console.log(x)", "console.log($A)", "console.log(x)"},
        {:typescript, "let a: number = 1", "let $A: number = $B", "let a: number = 1"},
        {:tsx, "const el = <div>{x}</div>", "<div>{$A}</div>", "<div>{x}</div>"},
        {:html, "<p><b>hi</b></p>", "<b>$A</b>", "<b>hi</b>"},
        {:css, "a { color: red; }", [kind: "declaration"], "color: red;"},
        {:rust, "fn main() { foo(1); }", "foo($A)", "foo(1)"},
        {:python, "print(x)", "print($A)", "print(x)"}
      ]

      for {language, source, pattern, text} <- samples do
        assert Atom.to_string(language) in AstGrep.languages()
        assert {:ok, [%Match{text: ^text}]} = AstGrep.find(source, pattern, language: language)
      end
    end

    test "the same rule files run with mix ast_grep.scan and mix credo", context do
      dir = project(context)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      assert_raise Mix.Error, fn -> File.cd!(dir, fn -> Mix.Tasks.AstGrep.Scan.run([]) end) end
      assert_received {:mix_shell, :info, ["lib/my_app.ex:3:5: warning[no-io-inspect]" <> _]}

      source_file(Path.join(dir, "lib/my_app.ex"))
      |> run_check(Check, config: Path.join(dir, "sgconfig.yml"))
      |> Enum.any?(&(&1.message == "[no-io-inspect] Remove IO.inspect(user)"))
      |> assert()
    end
  end

  describe "README: Installation" do
    test "builds from source with AST_GREP_BUILD=1, else defers to the app config" do
      # `AstGrep.Native` passes these options to `use RustlerPrecompiled`.
      # Without `:force_build`, RustlerPrecompiled reads
      # `config :rustler_precompiled, :force_build, ast_grep: true`.
      assert AstGrep.Native.Build.force_build_opts("1", :prod) == [force_build: true]
      assert AstGrep.Native.Build.force_build_opts(nil, :prod) == []
    end
  end

  describe "README: Writing rules" do
    test "loads an sgconfig.yml with ruleDirs and utilDirs" do
      rule_set = RuleSet.from_config!(@config)

      assert RuleSet.rule_ids(rule_set) == ["no-dbg", "no-io-inspect"]
      assert rule_set.root == @fixture

      assert [_no_dbg, no_io_inspect] = RuleSet.rules(rule_set)

      assert no_io_inspect == %Rule{
               id: "no-io-inspect",
               language: "elixir",
               severity: :warning,
               message: "Remove IO.inspect($A)",
               note: "IO.inspect/1 calls should not be committed.",
               url: nil,
               fixable: true,
               files: nil,
               ignores: ["test/**"],
               metadata: %{"credo_category" => "warning"}
             }
    end

    test "reports interpolated messages, notes and fixes, using utility rules" do
      rule_set = RuleSet.from_config!(@config)

      assert {:ok, [inspect, dbg, other]} =
               AstGrep.scan_file(Path.join(@fixture, "lib/my_app.ex"), rule_set)

      assert %Match{
               rule_id: "no-io-inspect",
               severity: :warning,
               message: "Remove IO.inspect(user)",
               note: "IO.inspect/1 calls should not be committed.",
               text: "IO.inspect(user)",
               range: %{start: %Position{line: 3, column: 5}}
             } = inspect

      assert inspect.fix.replacement == "user"

      # `matches: dbg-call`, from utils/dbg_call.yml.
      assert %Match{rule_id: "no-dbg", severity: :error, text: "dbg(user)", fix: nil} = dbg
      assert %Match{rule_id: "no-io-inspect", text: "IO.inspect(:other_rule_ignored)"} = other
    end

    test "ignores: test/** skips the files under test/" do
      rule_set = RuleSet.from_config!(@config)
      source = File.read!(Path.join(@fixture, "test/support.exs"))

      assert AstGrep.scan_file!(Path.join(@fixture, "test/support.exs"), rule_set) == []
      assert AstGrep.scan!(source, rule_set, path: "test/support.exs") == []
      assert AstGrep.scan!(source, rule_set, path: "test/nested/support.exs") == []

      assert [%Match{rule_id: "no-io-inspect"}] =
               AstGrep.scan!(source, rule_set, path: "lib/support.exs")
    end

    test "# ast-grep-ignore and # ast-grep-ignore: rule-id suppress matches" do
      rule_set = RuleSet.from_config!(@config)

      source = """
      IO.inspect(:reported)
      # ast-grep-ignore
      IO.inspect(:suppressed)
      # ast-grep-ignore
      dbg(:suppressed)
      # ast-grep-ignore: no-io-inspect
      IO.inspect(:suppressed_by_id)
      # ast-grep-ignore: no-dbg
      IO.inspect(:other_id_reported)
      # ast-grep-ignore: no-dbg
      dbg(:suppressed_by_id)
      """

      assert source
             |> AstGrep.scan!(rule_set, language: :elixir)
             |> Enum.map(&{&1.rule_id, &1.text}) == [
               {"no-io-inspect", "IO.inspect(:reported)"},
               {"no-io-inspect", "IO.inspect(:other_id_reported)"}
             ]
    end
  end

  describe "README: Credo integration - All rules in one check" do
    @lib_issues [
      {3, "[no-io-inspect] Remove IO.inspect(user)"},
      {4, "[no-dbg] Remove dbg calls"},
      {11, "[no-io-inspect] Remove IO.inspect(:other_rule_ignored)"}
    ]

    test "loads the nearest sgconfig.yml and reports `[rule-id] message`", context do
      dir = project(context)

      # From a subdirectory: the config is found in a parent directory.
      File.cd!(Path.join(dir, "lib"), fn ->
        issues = "my_app.ex" |> source_file() |> run_check(Check, [])
        assert summary(issues) == @lib_issues
        assert Enum.all?(issues, &(&1.check == Check))
      end)
    end

    test "config: a path, or false" do
      assert source_file() |> run_check(Check, config: @config) |> summary() == @lib_issues
      source_file() |> run_check(Check, config: false) |> refute_issues()
    end

    test "paths: and utils: add rules and utility rules" do
      priv_rules = Path.join(@fixture, "priv/ast_grep/rules")

      assert source_file()
             |> run_check(Check, config: @config, paths: [priv_rules])
             |> summary() ==
               Enum.sort(@lib_issues ++ [{5, "[no-string-to-atom] " <> to_atom_message()}])

      assert source_file()
             |> run_check(Check,
               config: false,
               paths: [Path.join(@fixture, "rules/no_dbg.yml")],
               utils: [Path.join(@fixture, "utils")]
             )
             |> summary() == [{4, "[no-dbg] Remove dbg calls"}]
    end

    test "only: and except: select rules by id" do
      assert source_file() |> run_check(Check, config: @config, only: ["no-dbg"]) |> summary() ==
               [{4, "[no-dbg] Remove dbg calls"}]

      assert source_file()
             |> run_check(Check, config: @config, except: ["some-rule", "no-dbg"])
             |> summary() == @lib_issues -- [{4, "[no-dbg] Remove dbg calls"}]
    end

    test "category: sets the category of rules without metadata.credo_category" do
      categories =
        source_file()
        |> run_check(Check, config: @config, category: :readability)
        |> Map.new(&{&1.trigger, &1.category})

      # no-io-inspect sets `metadata.credo_category: warning`.
      assert categories == %{
               "IO.inspect(user)" => :warning,
               "dbg(user)" => :readability,
               "IO.inspect(:other_rule_ignored)" => :warning
             }
    end
  end

  describe "README: Credo integration - One Credo check per rule" do
    test "file: defines a check from a rule file" do
      source_file()
      |> run_check(NoStringToAtom)
      |> assert_issue(%{
        check: NoStringToAtom,
        message: to_atom_message(),
        trigger: "String.to_atom(user.name)",
        line_no: 5,
        column: 5
      })

      assert %Rule{id: "no-string-to-atom"} = NoStringToAtom.rule()
      assert NoStringToAtom.id() == "AstGrep.FeaturesTest.NoStringToAtom"
    end

    test "has its own `mix credo explain` text" do
      explanation = NoStringToAtom.explanations()[:check]

      assert explanation =~ "String.to_atom/1 can exhaust the atom table"
      assert explanation =~ "Use String.to_existing_atom/1 instead."
      assert explanation =~ "See: https://example.com/rules/no-string-to-atom"
      assert NoStringToAtom.docs_uri() == "https://example.com/rules/no-string-to-atom"
    end

    test "recompiles when the YAML file changes" do
      resources =
        NoIoInspect.__info__(:attributes)
        |> Keyword.get_values(:external_resource)
        |> List.flatten()

      assert "test/fixtures/readme/rules/no_io_inspect.yml" in resources
      assert "test/fixtures/readme/sgconfig.yml" in resources
      assert "test/fixtures/readme/utils/dbg_call.yml" in resources
    end

    test "rule: accepts inline YAML, maps and keyword lists" do
      source_file() |> run_check(InlineYaml) |> assert_issue(%{message: "Remove dbg(user)"})

      source_file()
      |> run_check(InlineMap)
      |> assert_issue(%{message: "Avoid String.to_atom(user.name)"})

      source_file()
      |> run_check(InlineKeyword)
      |> assert_issue(%{message: "Avoid String.to_atom/1"})
    end

    test "utils: and config: provide utility rules" do
      source_file() |> run_check(WithUtils) |> assert_issue(%{message: "dbg via :utils"})
      source_file() |> run_check(WithConfig) |> assert_issue(%{message: "dbg via :config"})
    end

    test "config: makes files/ignores globs relative to the config's directory" do
      test_file = to_source_file("IO.inspect(:x)", Path.join(@fixture, "test/support.exs"))
      lib_file = to_source_file("IO.inspect(:x)", Path.join(@fixture, "lib/support.ex"))

      test_file |> run_check(NoIoInspect) |> refute_issues()
      lib_file |> run_check(NoIoInspect) |> assert_issue(%{message: "Remove IO.inspect(:x)"})
    end

    test "category:, base_priority: and id: options" do
      assert InlineKeyword.id() == "AG001"
      assert InlineKeyword.category() == :refactor
      assert InlineKeyword.base_priority() == :low

      source_file()
      |> run_check(InlineKeyword)
      |> assert_issue(%{
        check: InlineKeyword,
        category: :refactor,
        priority: Priority.to_integer(:low)
      })
    end

    test "rules in both the config's ruleDirs and a per-rule check are reported twice" do
      config_issues = source_file() |> run_check(Check, config: @config)
      rule_issues = source_file() |> run_check(NoIoInspect)

      for issues <- [config_issues, rule_issues] do
        assert Enum.any?(issues, &(&1.line_no == 3 and &1.trigger == "IO.inspect(user)"))
      end
    end
  end

  describe "README: Credo integration - Severity and category" do
    @severities [
      {"error", :higher},
      {"warning", :high},
      {"info", :normal},
      {"hint", :low},
      # no severity: ast-grep's default is `hint`
      {nil, :low}
    ]

    defp severity_rule(severity) do
      name = severity || "default"

      """
      id: sev-#{name}
      language: elixir
      message: severity #{name}
      #{if severity, do: "severity: #{severity}"}
      rule:
        pattern: sev_#{name}()
      """
    end

    test "maps every ast-grep severity to a Credo priority (AstGrep.Credo.Check)", %{
      tmp_dir: dir
    } do
      rules = Path.join(dir, "rules.yml")
      File.write!(rules, Enum.map_join(@severities, "---\n", &severity_rule(elem(&1, 0))))

      source =
        Enum.map_join(@severities, "\n", fn {severity, _} -> "sev_#{severity || "default"}()" end)

      priorities =
        source
        |> to_source_file("lib/sev.ex")
        |> run_check(Check, config: false, paths: [rules])
        |> Map.new(&{&1.message, {&1.priority, &1.category}})

      assert priorities ==
               Map.new(@severities, fn {severity, priority} ->
                 {"[sev-#{severity || "default"}] severity #{severity || "default"}",
                  {Priority.to_integer(priority), :warning}}
               end)
    end

    test "maps every ast-grep severity to a Credo priority (AstGrep.Credo.Rule)" do
      for {severity, priority} <- @severities do
        module = Module.concat(__MODULE__, "Severity#{System.unique_integer([:positive])}")

        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              use AstGrep.Credo.Rule, rule: unquote(severity_rule(severity))
            end
          end
        )

        assert module.base_priority() == priority
        assert module.category() == :warning
      end
    end

    test "metadata.credo_category and metadata.credo_priority override the defaults" do
      assert NoStringToAtom.category() == :design
      assert NoStringToAtom.base_priority() == :higher

      expected = %{category: :design, priority: Priority.to_integer(:higher)}
      source_file() |> run_check(NoStringToAtom) |> assert_issue(expected)

      source_file()
      |> run_check(Check,
        config: false,
        paths: [Path.join(@fixture, "priv/ast_grep/rules")]
      )
      |> assert_issue(expected)
    end

    test "hint issues are shown with --strict only; credo:disable comments work", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "rules"))
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "sgconfig.yml"), "ruleDirs: [rules]\n")
      File.write!(Path.join(dir, "rules/hint.yml"), severity_rule("hint"))
      File.write!(Path.join(dir, "rules/warning.yml"), severity_rule("warning"))

      File.write!(Path.join(dir, "lib/app.ex"), """
      defmodule App do
        def run do
          sev_hint()
          sev_warning()
          # credo:disable-for-next-line
          sev_warning()
        end
      end
      """)

      File.write!(Path.join(dir, ".credo.exs"), """
      %{
        configs: [
          %{
            name: "default",
            files: %{included: ["lib/"]},
            checks: %{enabled: [{AstGrep.Credo.Check, []}]}
          }
        ]
      }
      """)

      run = fn args ->
        File.cd!(dir, fn ->
          Credo.CLI.Output.Shell.suppress_output(fn -> send(self(), {:exec, Credo.run(args)}) end)
        end)

        assert_received {:exec, exec}
        exec |> Credo.Execution.get_issues() |> Enum.map(&{&1.line_no, &1.message}) |> Enum.sort()
      end

      assert run.([]) == [{4, "[sev-warning] severity warning"}]

      assert run.(["--strict"]) == [
               {3, "[sev-hint] severity hint"},
               {4, "[sev-warning] severity warning"}
             ]
    end

    test "files/ignores globs are relative to the sgconfig.yml directory", context do
      dir = project(context)
      config = Path.join(dir, "sgconfig.yml")

      # The current directory is not the project root: test/** must match
      # <project>/test/support.exs nonetheless.
      refute File.cwd!() == dir

      dir
      |> Path.join("test/support.exs")
      |> then(&to_source_file("IO.inspect(:x)", &1))
      |> run_check(Check, config: config)
      |> refute_issues()

      dir
      |> Path.join("lib/support.ex")
      |> then(&to_source_file("IO.inspect(:x)", &1))
      |> run_check(Check, config: config)
      |> assert_issue(%{message: "[no-io-inspect] Remove IO.inspect(:x)"})
    end
  end

  describe "README: Mix task" do
    setup context do
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
      %{dir: project(context)}
    end

    defp scan(dir, args) do
      File.cd!(dir, fn ->
        try do
          Mix.Tasks.AstGrep.Scan.run(args)
        rescue
          error in Mix.Error -> {:error, error.message}
        end
      end)
    end

    defp output(acc \\ []) do
      receive do
        {:mix_shell, kind, [message]} when kind in [:info, :error] -> output([message | acc])
      after
        0 -> acc |> Enum.reverse() |> Enum.join("\n")
      end
    end

    test "mix ast_grep.scan uses the nearest sgconfig.yml", %{dir: dir} do
      assert {:error, "ast-grep found 1 error"} = scan(Path.join(dir, "lib"), [])

      assert output() == """
             my_app.ex:3:5: warning[no-io-inspect] Remove IO.inspect(user)
                 IO.inspect/1 calls should not be committed.
             my_app.ex:4:5: error[no-dbg] Remove dbg calls
             my_app.ex:11:5: warning[no-io-inspect] Remove IO.inspect(:other_rule_ignored)
                 IO.inspect/1 calls should not be committed.
             Found 3 matches (1 error, 2 warnings) in 2 files.\
             """
    end

    test "mix ast_grep.scan lib --rule priv/ast_grep/rules", %{dir: dir} do
      assert {:error, "ast-grep found 1 error"} =
               scan(dir, ["lib", "--rule", "priv/ast_grep/rules"])

      out = output()

      assert out =~ """
             lib/my_app.ex:5:5: info[no-string-to-atom] String.to_atom/1 can exhaust the atom table
                 Use String.to_existing_atom/1 instead.
             """

      assert out =~ "Found 4 matches (1 error, 2 warnings, 1 info) in 1 file."
    end

    test "mix ast_grep.scan --fix applies the rules' fix rewrites", %{dir: dir} do
      assert {:error, "ast-grep found 1 error"} = scan(dir, ["--fix"])
      assert output() =~ "Applied 2 fixes to 1 file."

      fixed = File.read!(Path.join(dir, "lib/my_app.ex"))
      assert fixed =~ "\n    user\n    dbg(user)\n"
      assert fixed =~ "\n    :other_rule_ignored\n"
      assert fixed =~ "IO.inspect(:ignored)"
      # Ignored by `ignores: test/**`.
      assert File.read!(Path.join(dir, "test/support.exs")) == "IO.inspect(:in_test)\n"
    end

    test "exits with a non-zero status only if a match has severity error", %{dir: dir} do
      mix = System.find_executable("mix")
      config = Path.join(dir, "sgconfig.yml")

      run = fn args ->
        System.cmd(mix, ["ast_grep.scan" | args],
          cd: File.cwd!(),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )
      end

      assert {out, 1} = run.(["--config", config, dir])
      assert out =~ "Found 3 matches (1 error, 2 warnings) in 2 files."
      assert out =~ "ast-grep found 1 error"

      no_error_rule = Path.join(dir, "rules/no_io_inspect.yml")
      # Only warnings (without a config, test/** is relative to the cwd).
      assert {out, 0} = run.(["--no-config", "--rule", no_error_rule, dir])
      assert out =~ "Found 3 matches (3 warnings) in 2 files."
    end
  end

  describe "README: Library API" do
    @source """
    defmodule MyApp do
      def run(user) do
        IO.inspect(user, label: :x)
      end
    end
    """

    test "ad-hoc search with metavariables" do
      source = @source
      {:ok, [match]} = AstGrep.find(source, "IO.inspect($A, $$$OPTS)", language: :elixir)

      assert match.meta_variables == %{"A" => "user", "OPTS" => ["label: :x"]}
      assert match.range.start == %Position{line: 3, column: 5, offset: 42}
    end

    test "rule objects as maps / keyword lists" do
      {:ok, matches} =
        AstGrep.find(@source, [kind: "call", has: [pattern: "IO", stopBy: "end"]],
          language: :elixir
        )

      assert Enum.map(matches, &(&1.text |> String.split("\n") |> hd())) == [
               "defmodule MyApp do",
               "def run(user) do",
               "IO.inspect(user, label: :x)"
             ]
    end

    test "rewrite" do
      {:ok, new_source} =
        AstGrep.replace(@source, "IO.inspect($A, $$$OPTS)", "dbg($A)", language: :elixir)

      assert new_source == String.replace(@source, "IO.inspect(user, label: :x)", "dbg(user)")
    end

    test "lint with a rule set", context do
      dir = project(context)

      File.cd!(dir, fn ->
        rule_set = AstGrep.RuleSet.from_config!("sgconfig.yml")
        {:ok, matches} = AstGrep.scan_file("lib/my_app.ex", rule_set)
        fixed = AstGrep.apply_fixes(File.read!("lib/my_app.ex"), matches)

        assert Enum.map(matches, & &1.rule_id) == ["no-io-inspect", "no-dbg", "no-io-inspect"]
        assert fixed =~ "\n    user\n    dbg(user)\n"
        assert fixed =~ "\n    :other_rule_ignored\n"
      end)
    end

    test "inspect the syntax tree while writing rules" do
      {:ok, tree} = AstGrep.dump_tree("IO.inspect(x)", :elixir)

      assert tree == """
             source (1,1)-(1,14)
               call (1,1)-(1,14)
                 target: dot (1,1)-(1,11)
                   left: alias (1,1)-(1,3) "IO"
                   right: identifier (1,4)-(1,11) "inspect"
                 arguments (1,11)-(1,14)
                   identifier (1,12)-(1,13) "x"
             """
    end
  end

  defp to_atom_message, do: "String.to_atom/1 can exhaust the atom table"
end
