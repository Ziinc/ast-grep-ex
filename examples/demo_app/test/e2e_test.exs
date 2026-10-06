defmodule DemoApp.E2ETest do
  @moduledoc """
  The executable spec of this example: runs the real `mix` commands
  documented in the README and asserts their exact results.

  The commands run with `MIX_ENV=test`, the environment of the `mix test` run
  that starts them: it has just compiled the project and its deps, so the
  nested commands compile nothing. (With another environment, the `ast_grep`
  path dependency would be recompiled, rewriting the NIF shared library that
  this test VM has loaded.)

  Exclude these (slower) tests with `mix test --exclude e2e`.
  """
  use ExUnit.Case, async: true

  @moduletag :e2e
  @moduletag timeout: 600_000

  alias Credo.Priority

  @root Path.expand("..", __DIR__)
  @golden Path.join(@root, "test/golden")

  # The files making up the "scanned" project, copied for `--fix`.
  @project_files ~w(sgconfig.yml rules utils lib assets scripts)

  defp mix(args) do
    System.cmd("mix", args, cd: @root, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
  end

  defp issue({check, category, priority, file, line, column, message}) do
    %{
      "check" => inspect(check),
      "category" => to_string(category),
      "priority" => Priority.to_integer(priority),
      "filename" => file,
      "line_no" => line,
      "column" => column,
      "message" => message
    }
  end

  # Every Credo issue expected from `mix credo --strict`: no more, no less.
  # This proves that each rule is reported once (rules/ by AstGrep.Credo.Check,
  # priv/ast_grep/checks by the per-rule checks), that suppression comments,
  # globs, severities and metadata.credo_* overrides work, and that the
  # JavaScript rule is not run by Credo.
  @credo_issues [
    # rules/ via AstGrep.Credo.Check
    {
      AstGrep.Credo.Check,
      :warning,
      :high,
      "lib/demo_app/accounts.ex",
      10,
      12,
      "[no-io-inspect] Remove debugging call IO.inspect(build_user(params))"
    },
    {
      AstGrep.Credo.Check,
      :design,
      :high,
      "lib/demo_app/accounts.ex",
      15,
      3,
      "[bang-for-raising-functions] fetch_user/1 can raise: name it fetch_user! or return an error tuple"
    },
    {
      AstGrep.Credo.Check,
      :warning,
      :higher,
      "lib/demo_app/accounts.ex",
      34,
      5,
      "[no-dbg] Remove dbg/1 before committing"
    },
    {
      AstGrep.Credo.Check,
      :consistency,
      :normal,
      "lib/demo_app/accounts.ex",
      40,
      29,
      "[snake-case-atoms] Use :first_name instead of :firstName"
    },
    {
      AstGrep.Credo.Check,
      :refactor,
      :normal,
      "lib/demo_app/orders.ex",
      12,
      9,
      "[nested-case] Nested case on order.status: consider `with` or a helper function"
    },
    {
      AstGrep.Credo.Check,
      :readability,
      :low,
      "lib/demo_app/orders.ex",
      24,
      8,
      "[prefer-enum-empty] Use Enum.empty?(orders) instead of length(orders) == 0"
    },
    {
      AstGrep.Credo.Check,
      :warning,
      :normal,
      "lib/demo_app/orders.ex",
      41,
      5,
      "[no-io-puts-in-lib] Use Logger instead of IO.puts in library code"
    },
    {
      AstGrep.Credo.Check,
      :refactor,
      :normal,
      "lib/demo_app/orders.ex",
      44,
      5,
      "[prefer-direct-call] Call DemoApp.Mailer.deliver(...) directly instead of using apply/3"
    },
    # per-rule checks (credo_checks/)
    {
      DemoApp.Checks.NoStringToAtom,
      :design,
      :higher,
      "lib/demo_app/accounts.ex",
      23,
      23,
      "String.to_atom/1 can exhaust the atom table: use String.to_existing_atom/1"
    },
    {
      DemoApp.Checks.NoProcessSleep,
      :refactor,
      :normal,
      "lib/demo_app/orders.ex",
      43,
      5,
      "Avoid Process.sleep(100): it blocks the caller"
    }
  ]

  # Credo's exit status is the OR of the categories' bits: consistency (1),
  # design (2), readability (4), refactor (8), warning (16).
  @credo_exit_status 1 + 2 + 4 + 8 + 16

  defp credo(args) do
    {output, status} = mix(["credo", "--format", "json" | args])

    # Skip anything printed before the JSON document (e.g. compilation).
    json = output |> String.split("\n") |> Enum.drop_while(&(&1 != "{")) |> Enum.join("\n")

    issues =
      for issue <- Jason.decode!(json)["issues"] do
        Map.take(issue, ~w(check category priority filename line_no column message))
      end

    {Enum.sort_by(issues, &{&1["filename"], &1["line_no"]}), status}
  end

  defp expected_issues do
    @credo_issues |> Enum.map(&issue/1) |> Enum.sort_by(&{&1["filename"], &1["line_no"]})
  end

  describe "mix credo" do
    test "--strict reports exactly the expected issues" do
      {issues, status} = credo(["--strict"])
      assert issues == expected_issues()
      assert status == @credo_exit_status
    end

    test "without --strict, low priority issues (hint severity) are hidden" do
      {issues, _status} = credo([])
      expected = Enum.reject(expected_issues(), &(&1["priority"] < Priority.to_integer(:normal)))

      assert issues == expected
      refute Enum.any?(issues, &(&1["message"] =~ "[prefer-enum-empty]"))
      # nested-case is a hint too, but its metadata.credo_priority is normal.
      assert Enum.any?(issues, &(&1["message"] =~ "[nested-case]"))
    end
  end

  # The match lines printed by `mix ast_grep.scan` (notes excluded).
  @scan_matches [
    ~s|assets/js/app.js:4:3: warning[no-console-log] Remove console.log("booting app for", user.name)|,
    "lib/demo_app/accounts.ex:10:12: warning[no-io-inspect] Remove debugging call IO.inspect(build_user(params))",
    "lib/demo_app/accounts.ex:15:3: warning[bang-for-raising-functions] fetch_user/1 can raise: name it fetch_user! or return an error tuple",
    "lib/demo_app/accounts.ex:34:5: error[no-dbg] Remove dbg/1 before committing",
    "lib/demo_app/accounts.ex:40:29: info[snake-case-atoms] Use :first_name instead of :firstName",
    "lib/demo_app/orders.ex:12:9: hint[nested-case] Nested case on order.status: consider `with` or a helper function",
    "lib/demo_app/orders.ex:24:8: hint[prefer-enum-empty] Use Enum.empty?(orders) instead of length(orders) == 0",
    "lib/demo_app/orders.ex:41:5: info[no-io-puts-in-lib] Use Logger instead of IO.puts in library code",
    "lib/demo_app/orders.ex:44:5: info[prefer-direct-call] Call DemoApp.Mailer.deliver(...) directly instead of using apply/3"
  ]

  defp match_lines(output, prefix \\ "") do
    output
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\S+:\d+:\d+: \w+\[/, &1))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  describe "mix ast_grep.scan" do
    test "reports the matches of all rules, including the JavaScript one" do
      {output, status} = mix(["ast_grep.scan"])

      assert match_lines(output) == @scan_matches
      assert output =~ ~r/Found 9 matches \(1 error, 3 warnings, 3 infos, 2 hints\) in \d+ files/
      # Notes are printed under their match.
      assert output =~ "    By convention, functions that raise end with `!`"
      # The error-severity no-dbg match makes the task fail.
      assert output =~ "** (Mix) ast-grep found 1 error"
      assert status == 1
    end

    test "--fix rewrites the files as in test/golden/" do
      tmp = Path.join(System.tmp_dir!(), "demo_app_fix_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      for file <- @project_files, do: File.cp_r!(Path.join(@root, file), Path.join(tmp, file))

      # Scan the copy: its sgconfig.yml makes it the project root.
      {output, status} =
        mix(["ast_grep.scan", "--config", Path.join(tmp, "sgconfig.yml"), "--fix"])

      assert output =~ "Applied 4 fixes to 2 files."

      # Only the matches without a fix remain.
      fixable = ~w(no-io-inspect snake-case-atoms prefer-enum-empty prefer-direct-call)

      assert match_lines(output, tmp <> "/") ==
               Enum.reject(@scan_matches, fn line ->
                 Enum.any?(fixable, &String.contains?(line, "[#{&1}]"))
               end)

      assert status == 1

      golden = for path <- Path.wildcard(Path.join(@golden, "**/*.fixed")), do: path

      assert Enum.map(golden, &Path.relative_to(&1, @golden)) == [
               "lib/demo_app/accounts.ex.fixed",
               "lib/demo_app/orders.ex.fixed"
             ]

      for path <- Path.wildcard(Path.join(tmp, "**/*"), match_dot: true), File.regular?(path) do
        relative = Path.relative_to(path, tmp)
        golden_path = Path.join(@golden, relative <> ".fixed")

        expected =
          if File.exists?(golden_path),
            do: File.read!(golden_path),
            else: File.read!(Path.join(@root, relative))

        assert File.read!(path) == expected, "#{relative} differs from the expected output"
      end

      # The fixed code is still valid Elixir.
      for path <- golden, do: Code.string_to_quoted!(File.read!(path))
    end
  end

  describe "mix run scripts/api_tour.exs" do
    test "runs the tour of the API" do
      {output, status} = mix(["run", "scripts/api_tour.exs"])
      assert status == 0, output

      for line <- [
            # find/3 with a pattern and metavariables
            ~s|line 3: IO.inspect(cart, label: "cart")|,
            ~s|  $VALUE = "cart"|,
            ~s|  $$$OPTS = ["label: \\"cart\\""]|,
            # find/3 with a rule map
            ~s|line 5: Logger.info("checkout", user_id: user.id, total: total)|,
            # replace/4
            "+     total = Enum.sum_by(cart.items, & &1.price)",
            # RuleSet.from_config!/1 + scan_file/2
            "error   no-dbg",
            "lib/demo_app/accounts.ex:34:5 no-dbg: Remove dbg/1 before committing",
            # apply_fixes/2
            "-     user = IO.inspect(build_user(params))",
            "+     user = build_user(params)",
            "+       name: Map.get(params, :first_name),",
            # RuleSet.filter/2
            ~s|only: ["no-dbg", "no-io-inspect"]|,
            # scan/3 with a path (files/ignores globs)
            "lib/demo_app/orders.ex => 1 match(es)",
            "lib/demo_app/cli.ex => 0 match(es)",
            # dump_tree/2
            "    target: dot (1,1)-(1,11)",
            # languages/0
            "elixir, go"
          ] do
        assert output =~ line
      end
    end
  end
end
