defmodule AstGrepTest do
  use ExUnit.Case, async: true

  alias AstGrep.{Error, Fix, Match, Position, Range, RuleSet}

  doctest AstGrep

  @project Path.expand("fixtures/project", __DIR__)

  describe "find/3" do
    test "matches a pattern and captures single metavariables" do
      source = """
      IO.inspect(user)
      IO.puts(user)
      IO.inspect(%{a: 1})
      """

      assert {:ok, [first, second]} = AstGrep.find(source, "IO.inspect($A)", language: :elixir)

      assert %Match{rule_id: "find", language: "elixir", kind: "call", text: "IO.inspect(user)"} =
               first

      assert first.meta_variables == %{"A" => "user"}
      assert second.meta_variables == %{"A" => "%{a: 1}"}

      assert first.range == %Range{
               start: %Position{line: 1, column: 1, offset: 0},
               end: %Position{line: 1, column: 17, offset: 16}
             }

      assert second.range.start == %Position{line: 3, column: 1, offset: 31}
    end

    test "captures multi metavariables as lists" do
      assert {:ok, [match]} = AstGrep.find("foo(1, b, :c)", "foo($$$ARGS)", language: "elixir")
      assert match.meta_variables == %{"ARGS" => ["1", "b", ":c"]}

      assert {:ok, [match]} = AstGrep.find("foo()", "foo($$$ARGS)", language: "elixir")
      assert match.meta_variables == %{"ARGS" => []}
    end

    test "accepts language aliases and infers the language from :path" do
      assert {:ok, [_]} = AstGrep.find("foo(1)", "foo($A)", language: "Elixir")
      assert {:ok, [_]} = AstGrep.find("foo(1)", "foo($A)", language: :ex)
      assert {:ok, [_]} = AstGrep.find("foo(1)", "foo($A)", path: "lib/a.ex")
      assert {:ok, [_]} = AstGrep.find("foo(1);", "foo($A)", language: :js)
    end

    test "accepts rule objects as maps and keyword lists" do
      source = """
      def a, do: IO.puts("x")
      def b, do: Logger.info("x")
      """

      rule = %{kind: "call", has: %{pattern: "IO", stopBy: "end"}, not: %{pattern: "IO"}}
      assert {:ok, matches} = AstGrep.find(source, rule, language: :elixir)
      assert "IO.puts(\"x\")" in Enum.map(matches, & &1.text)
      refute Enum.any?(matches, &(&1.text =~ "Logger"))

      assert {:ok, [match]} =
               AstGrep.find(
                 source,
                 [pattern: "$M.info($$$)", inside: [kind: "call", stopBy: "end"]],
                 language: :elixir
               )

      assert match.meta_variables["M"] == "Logger"
    end

    test "supports constraints, local utils and transforms" do
      source = "foo(a)\nfoo(1)\nfoo(:b)"

      assert {:ok, [match]} =
               AstGrep.find(source, "foo($A)",
                 language: :elixir,
                 constraints: %{A: %{kind: "identifier"}}
               )

      assert match.text == "foo(a)"

      assert {:ok, [match]} =
               AstGrep.find(source, %{matches: "atom-call"},
                 language: :elixir,
                 utils: %{
                   "atom-call" => %{pattern: "foo($A)", has: %{kind: "atom", stopBy: "end"}}
                 }
               )

      assert match.text == "foo(:b)"

      assert {:ok, "foo(A)\nfoo(1)\nfoo(:b)"} =
               AstGrep.replace(source, "foo($A)", "foo($UP)",
                 language: :elixir,
                 constraints: %{A: %{kind: "identifier"}},
                 transform: %{UP: %{convert: %{source: "$A", toCase: "upperCase"}}}
               )
    end

    test "returns all nested matches" do
      assert {:ok, matches} = AstGrep.find("foo(foo(1))", "foo($A)", language: :elixir)
      assert Enum.map(matches, & &1.text) == ["foo(foo(1))", "foo(1)"]
    end

    test "returns errors" do
      assert {:error, %Error{message: message}} = AstGrep.find("foo", "foo")
      assert message =~ ":language option is required"

      assert {:error, %Error{message: message}} = AstGrep.find("foo", "foo", language: :cobol)
      assert message =~ "cobol is not supported"

      assert {:error, %Error{message: message}} = AstGrep.find("foo", "foo", path: "a.unknown")
      assert message =~ "cannot infer language"

      assert {:error, %Error{message: message}} =
               AstGrep.find("foo", "foo((", language: :elixir)

      assert message =~ "invalid pattern"

      assert_raise Error, fn -> AstGrep.find!("foo", "foo((", language: :elixir) end
      assert [%Match{}] = AstGrep.find!("foo", "foo", language: :elixir)
    end
  end

  describe "replace/4" do
    test "rewrites matches with metavariables" do
      source = """
      x = IO.inspect(user)
      IO.inspect(:other, label: "x")
      """

      assert AstGrep.replace(source, "IO.inspect($A)", "dbg($A)", language: :elixir) ==
               {:ok, "x = dbg(user)\nIO.inspect(:other, label: \"x\")\n"}

      assert AstGrep.replace!(source, "IO.inspect($$$ARGS)", "dbg($$$ARGS)", language: :elixir) ==
               "x = dbg(user)\ndbg(:other, label: \"x\")\n"
    end

    test "keeps the outermost of nested matches" do
      assert AstGrep.replace("foo(foo(1))", "foo($A)", "bar($A)", language: :elixir) ==
               {:ok, "bar(foo(1))"}
    end

    test "supports fix configs with expandEnd" do
      fix = %{template: "", expandEnd: %{regex: ","}}

      assert AstGrep.replace("[foo(1), 2]", "foo($A)", fix, language: :elixir) ==
               {:ok, "[ 2]"}
    end

    test "returns the source unchanged without matches" do
      assert AstGrep.replace("bar()", "foo()", "baz()", language: :elixir) == {:ok, "bar()"}
    end
  end

  describe "apply_fixes/2" do
    defp fix(start, stop, replacement) do
      %Fix{
        replacement: replacement,
        range: %Range{start: %Position{offset: start}, end: %Position{offset: stop}}
      }
    end

    test "applies fixes in offset order regardless of input order" do
      source = "aaa bbb ccc"
      fixes = [fix(8, 11, "C"), fix(0, 3, "A"), fix(4, 7, "B")]
      assert AstGrep.apply_fixes(source, fixes) == "A B C"
    end

    test "skips fixes overlapping an already applied one" do
      source = "0123456789"
      fixes = [fix(2, 6, "x"), fix(4, 8, "y"), fix(0, 2, "z"), fix(6, 7, "w")]
      assert AstGrep.apply_fixes(source, fixes) == "zxw789"
    end

    test "ignores matches without a fix and supports insertions" do
      matches = [
        %Match{fix: nil},
        %Match{fix: fix(0, 0, "<")},
        %Match{fix: fix(3, 3, ">")}
      ]

      assert AstGrep.apply_fixes("abc", matches) == "<abc>"
      assert AstGrep.apply_fixes("abc", []) == "abc"
    end

    test "uses byte offsets with multi-byte characters" do
      source = "x = \"héllo\"\nIO.inspect(\"é\")\n"
      {:ok, matches} = AstGrep.find(source, "IO.inspect($A)", language: :elixir, fix: "$A")
      assert AstGrep.apply_fixes(source, matches) == "x = \"héllo\"\n\"é\"\n"
    end
  end

  describe "scan/3" do
    setup do
      %{rule_set: RuleSet.from_config!(Path.join(@project, "sgconfig.yml"))}
    end

    test "reports severities and interpolated messages", %{rule_set: rule_set} do
      source = File.read!(Path.join(@project, "lib/example.ex"))
      assert {:ok, matches} = AstGrep.scan(source, rule_set, path: "lib/example.ex")

      assert Enum.map(matches, &{&1.range.start.line, &1.rule_id, &1.severity}) == [
               {3, "no-io-inspect", :warning},
               {4, "no-dbg", :error},
               {5, "no-apply-in-lib", :info},
               {7, "prefer-enum-empty", :hint}
             ]

      [inspect, _dbg, _apply, empty] = matches
      assert inspect.message == "Remove IO.inspect(user)"
      assert inspect.note == "IO.inspect/1 calls are debugging leftovers."
      assert inspect.url == "https://example.com/rules/no-io-inspect"
      assert inspect.fix.replacement == "user"
      assert empty.message == "Use Enum.empty?(user.items) instead of length(user.items) == 0"
    end

    test "honors ast-grep-ignore comments", %{rule_set: rule_set} do
      source = """
      IO.inspect(1)
      # ast-grep-ignore
      IO.inspect(2)
      IO.inspect(3) # ast-grep-ignore
      # ast-grep-ignore: no-io-inspect
      IO.inspect(4)
      # ast-grep-ignore: no-dbg
      IO.inspect(5)
      """

      assert {:ok, matches} = AstGrep.scan(source, rule_set, language: :elixir)
      assert Enum.map(matches, & &1.text) == ["IO.inspect(1)", "IO.inspect(5)"]
    end

    test "matches files and ignores globs against :path", %{rule_set: rule_set} do
      source = "apply(Foo, :bar, [])"
      ids = fn opts -> source |> AstGrep.scan!(rule_set, opts) |> Enum.map(& &1.rule_id) end

      assert ids.(path: "lib/foo.ex") == ["no-apply-in-lib"]
      assert ids.(path: "./lib/foo.ex") == ["no-apply-in-lib"]
      assert ids.(path: "lib/nested/foo.ex") == ["no-apply-in-lib"]
      assert ids.(path: "lib/generated/foo.ex") == []
      assert ids.(path: "scripts/foo.exs") == []
      assert ids.(language: :elixir) == []
    end

    test "only runs rules of the source language", %{rule_set: rule_set} do
      assert AstGrep.scan("IO.inspect(1)", rule_set, language: :ruby) == {:ok, []}
    end

    test "returns errors", %{rule_set: rule_set} do
      assert {:error, %Error{message: message}} = AstGrep.scan("x", rule_set)
      assert message =~ "language or a path is required"

      assert {:error, %Error{}} = AstGrep.scan("x", rule_set, language: :nope)

      assert {:error, %Error{path: "foo.unknown"}} =
               AstGrep.scan("x", rule_set, path: "foo.unknown")

      assert_raise Error, fn -> AstGrep.scan!("x", rule_set) end
    end
  end

  describe "scan_file/3" do
    setup do
      %{
        rule_set: RuleSet.load!(Path.join(@project, "rules"), utils: Path.join(@project, "utils"))
      }
    end

    test "matches globs relative to :root", %{rule_set: rule_set} do
      lib_file = Path.join(@project, "lib/example.ex")
      generated = Path.join(@project, "lib/generated/generated.ex")

      ids = fn path, opts ->
        path |> AstGrep.scan_file!(rule_set, opts) |> Enum.map(& &1.rule_id)
      end

      assert "no-apply-in-lib" in ids.(lib_file, root: @project)
      assert ids.(generated, root: @project) == []
      # Relative to the current directory the file is not under lib/.
      refute "no-apply-in-lib" in ids.(lib_file, [])
    end

    test "defaults :root to the rule set's root" do
      rule_set = RuleSet.from_config!(Path.join(@project, "sgconfig.yml"))
      assert {:ok, matches} = AstGrep.scan_file(Path.join(@project, "lib/example.ex"), rule_set)
      assert "no-apply-in-lib" in Enum.map(matches, & &1.rule_id)
    end

    test "returns an error for unreadable files", %{rule_set: rule_set} do
      path = Path.join(@project, "missing.ex")
      assert {:error, %Error{path: ^path, message: message}} = AstGrep.scan_file(path, rule_set)
      assert message =~ "no such file"
    end
  end

  describe "languages and trees" do
    test "languages/0" do
      languages = AstGrep.languages()
      assert "elixir" in languages
      assert "typescript" in languages
    end

    test "normalize_language/1" do
      assert AstGrep.normalize_language(:elixir) == {:ok, "elixir"}
      assert AstGrep.normalize_language("JavaScript") == {:ok, "javascript"}
      assert {:error, %Error{}} = AstGrep.normalize_language(nil)
      assert {:error, %Error{}} = AstGrep.normalize_language(123)
    end

    test "dump_tree/2" do
      assert {:ok, tree} = AstGrep.dump_tree("foo(1)", "ex")
      assert tree =~ "call (1,1)-(1,7)"
      assert {:error, %Error{}} = AstGrep.dump_tree("foo", :nope)
    end
  end
end
