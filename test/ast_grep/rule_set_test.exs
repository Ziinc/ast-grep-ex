defmodule AstGrep.RuleSetTest do
  use ExUnit.Case, async: true

  alias AstGrep.{Error, Rule, RuleSet}

  doctest AstGrep.RuleSet

  @moduletag :tmp_dir

  @project Path.expand("../fixtures/project", __DIR__)

  @yaml """
  id: no-io-inspect
  language: elixir
  severity: warning
  message: Remove IO.inspect($A)
  rule:
    pattern: IO.inspect($A)
  fix: $A
  """

  describe "compile/2" do
    test "compiles a YAML rule" do
      assert {:ok, %RuleSet{rules: [rule]} = rule_set} = RuleSet.compile(@yaml)

      assert %Rule{
               id: "no-io-inspect",
               language: "elixir",
               severity: :warning,
               message: "Remove IO.inspect($A)",
               fixable: true,
               files: nil
             } = rule

      assert RuleSet.rules(rule_set) == [rule]
      assert is_reference(rule_set.ref)
    end

    test "compiles maps, keyword lists and multi-document YAML" do
      multi = """
      id: b
      language: elixir
      rule:
        pattern: b()
      ---
      id: off-rule
      language: elixir
      severity: off
      rule:
        pattern: c()
      """

      rules = [
        multi,
        %{id: "a", language: :elixir, severity: :error, rule: %{pattern: "a()"}},
        [id: "c", language: "ex", rule: [kind: "call", has: [pattern: "c"]]]
      ]

      assert {:ok, rule_set} = RuleSet.compile(rules)
      assert RuleSet.rule_ids(rule_set) == ["a", "b", "c"]

      assert {:ok, rule_set} = RuleSet.compile(id: "kw", language: :elixir, rule: [pattern: "x"])
      assert RuleSet.rule_ids(rule_set) == ["kw"]
    end

    test "compiles rules referencing global utility rules" do
      util = %{id: "is-dbg", language: "elixir", rule: %{pattern: "dbg($$$)"}}
      rule = %{id: "no-dbg", language: "elixir", rule: %{matches: "is-dbg"}}

      assert {:ok, rule_set} = RuleSet.compile(rule, utils: util)
      assert [%{rule_id: "no-dbg"}] = AstGrep.scan!("dbg(x)", rule_set, language: :elixir)

      assert {:error, %Error{message: message}} = RuleSet.compile(rule)
      assert message =~ "`is-dbg` is not defined"
    end

    test "returns errors for invalid rules" do
      assert {:error, %Error{message: message, path: nil}} = RuleSet.compile("id: x\nrule: [\n")
      assert message =~ "invalid rule YAML"

      assert {:error, %Error{message: message}} =
               RuleSet.compile(%{id: "x", language: "elixir", rule: %{pattern: "foo(("}})

      assert message =~ "invalid rule `x`"
      assert message =~ "pattern"

      assert {:error, %Error{message: message}} =
               RuleSet.compile(%{id: "x", language: "cobol", rule: %{pattern: "foo"}})

      assert message =~ "cobol is not supported"

      assert {:error, %Error{message: message}} =
               RuleSet.compile(%{
                 id: "x",
                 language: "elixir",
                 rule: %{pattern: "x"},
                 files: ["["]
               })

      assert message =~ "glob"

      assert_raise Error, ~r/invalid rule/, fn -> RuleSet.compile!("id: x\nrule: [\n") end
    end

    test "stores :root" do
      assert RuleSet.compile!(@yaml).root == nil
      assert RuleSet.compile!(@yaml, root: "/tmp/project").root == "/tmp/project"
    end
  end

  describe "load/2" do
    test "loads rule directories recursively with utils" do
      assert {:ok, rule_set} = RuleSet.load("rules", root: @project, utils: ["utils"])

      assert RuleSet.rule_ids(rule_set) ==
               ["no-apply-in-lib", "no-dbg", "no-io-inspect", "prefer-enum-empty"]

      assert rule_set.root == @project

      [_, _, inspect, _] = RuleSet.rules(rule_set)
      assert inspect.metadata == %{"category" => "debugging"}
      assert inspect.note == "IO.inspect/1 calls are debugging leftovers."
    end

    test "loads individual files and inline rules" do
      assert {:ok, rule_set} =
               RuleSet.load([Path.join(@project, "rules/style.yaml")],
                 rules: [%{id: "inline", language: "elixir", rule: %{pattern: "x"}}]
               )

      assert RuleSet.rule_ids(rule_set) == ["inline", "prefer-enum-empty"]
      assert rule_set.root == nil
    end

    test "walks nested directories and skips empty files", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "rules/nested"))
      File.write!(Path.join(dir, "rules/nested/a.yaml"), @yaml)
      File.write!(Path.join(dir, "rules/empty.yml"), "# nothing here\n")
      File.write!(Path.join(dir, "rules/notes.txt"), "not a rule")

      assert {:ok, rule_set} = RuleSet.load(Path.join(dir, "rules"))
      assert RuleSet.rule_ids(rule_set) == ["no-io-inspect"]
    end

    test "fails when a utility rule is missing" do
      assert {:error, %Error{message: message}} = RuleSet.load("rules", root: @project)
      assert message =~ "`dbg-call` is not defined"
      assert message =~ "no_dbg.yml"
    end

    test "attributes YAML errors to the file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "good.yml"), @yaml)
      bad = Path.join(dir, "bad.yml")
      File.write!(bad, "id: x\nrule: [\n")

      assert {:error, %Error{path: ^bad, message: message}} = RuleSet.load(dir)
      assert message =~ "bad.yml: invalid YAML"
    end

    test "attributes invalid patterns and languages to the file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a_good.yml"), @yaml)
      bad = Path.join(dir, "b_bad.yml")

      File.write!(bad, "id: bad-pattern\nlanguage: elixir\nrule:\n  pattern: 'foo(('\n")
      assert {:error, %Error{path: ^bad, message: message}} = RuleSet.load(dir)
      assert message =~ "b_bad.yml: invalid rule `bad-pattern`"

      File.write!(bad, "id: bad-language\nlanguage: cobol\nrule:\n  pattern: foo\n")
      assert {:error, %Error{path: ^bad, message: message}} = RuleSet.load(dir)
      assert message =~ "b_bad.yml"
      assert message =~ "cobol is not supported"
    end

    test "attributes utility rule errors to the file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "rule.yml"), @yaml)
      File.mkdir_p!(Path.join(dir, "utils"))
      File.write!(Path.join(dir, "utils/a.yml"), "id: a\nlanguage: elixir\nrule:\n  pattern: a\n")
      bad = Path.join(dir, "utils/b.yml")
      File.write!(bad, "id: b\nlanguage: elixir\nrule:\n  pattern: 'b(('\n")

      assert {:error, %Error{path: ^bad, message: message}} =
               RuleSet.load(Path.join(dir, "rule.yml"), utils: Path.join(dir, "utils"))

      assert message =~ "invalid utility rules"
    end

    test "fails on missing paths", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")
      assert {:error, %Error{path: ^missing, message: message}} = RuleSet.load(missing)
      assert message =~ "no such file or directory"

      assert_raise Error, fn -> RuleSet.load!(missing) end
    end
  end

  describe "from_config/2" do
    test "loads the config's rule and util dirs" do
      assert {:ok, rule_set} = RuleSet.from_config(Path.join(@project, "sgconfig.yml"))
      assert "no-dbg" in RuleSet.rule_ids(rule_set)
      assert rule_set.root == @project
    end

    test "accepts extra inline rules" do
      rule_set =
        RuleSet.from_config!(Path.join(@project, "sgconfig.yml"),
          rules: "id: extra\nlanguage: elixir\nrule:\n  matches: dbg-call\n"
        )

      assert "extra" in RuleSet.rule_ids(rule_set)
    end

    test "returns config errors" do
      assert {:error, %Error{message: message}} =
               RuleSet.from_config(Path.join(@project, "nope.yml"))

      assert message =~ "cannot read config"
      assert_raise Error, fn -> RuleSet.from_config!(Path.join(@project, "nope.yml")) end
    end
  end

  describe "filter/2" do
    setup do
      %{rule_set: RuleSet.from_config!(Path.join(@project, "sgconfig.yml"))}
    end

    test "keeps only the given rules", %{rule_set: rule_set} do
      filtered = RuleSet.filter(rule_set, only: ["no-dbg", "prefer-enum-empty", "unknown"])
      assert RuleSet.rule_ids(filtered) == ["no-dbg", "prefer-enum-empty"]
      assert filtered.root == rule_set.root

      source = File.read!(Path.join(@project, "lib/example.ex"))

      assert source
             |> AstGrep.scan!(filtered, path: "lib/example.ex")
             |> Enum.map(& &1.rule_id) == ["no-dbg", "prefer-enum-empty"]
    end

    test "drops the excepted rules", %{rule_set: rule_set} do
      filtered = RuleSet.filter(rule_set, except: "no-dbg")

      assert RuleSet.rule_ids(filtered) == [
               "no-apply-in-lib",
               "no-io-inspect",
               "prefer-enum-empty"
             ]

      filtered = RuleSet.filter(rule_set, only: [:"no-dbg", "no-io-inspect"], except: ["no-dbg"])
      assert RuleSet.rule_ids(filtered) == ["no-io-inspect"]
      assert RuleSet.filter(filtered, only: []) |> RuleSet.rule_ids() == []
    end

    test "returns the same rule set when nothing is filtered", %{rule_set: rule_set} do
      assert RuleSet.filter(rule_set, []) == rule_set
      assert RuleSet.filter(rule_set, except: ["unknown"]) == rule_set
    end

    test "works with inline sources" do
      rule_set =
        RuleSet.compile!([
          %{id: "a", language: "elixir", rule: %{pattern: "a()"}},
          [id: "b", language: :elixir, rule: [pattern: "b()"]],
          "id: c\nlanguage: elixir\nrule:\n  pattern: c()\n---\nid: d\nlanguage: elixir\nrule:\n  pattern: d()\n"
        ])

      filtered = RuleSet.filter(rule_set, only: ~w(b d))
      assert RuleSet.rule_ids(filtered) == ["b", "d"]

      assert "a()\nb()\nc()\nd()"
             |> AstGrep.scan!(filtered, language: :elixir)
             |> Enum.map(& &1.text) == ["b()", "d()"]
    end
  end
end
