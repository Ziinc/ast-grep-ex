defmodule AstGrep.Credo.CheckTest do
  use Credo.Test.Case

  import ExUnit.CaptureIO

  alias AstGrep.Credo.Check
  alias Credo.Priority

  @root Path.expand("../../fixtures/credo", __DIR__)
  @config Path.join(@root, "sgconfig.yml")

  @source """
  defmodule Sample do
    def run(user) do
      IO.inspect(user)
      dbg(user)
      apply(Sample, :other, [user])

      if length(user.items) == 0 do
        :empty
      end

      # ast-grep-ignore
      IO.inspect(:suppressed)
      String.to_atom(user.name)
    end
  end
  """

  defp source_file(filename, source \\ @source), do: to_source_file(source, filename)

  # A source file whose filename is inside the fixture project.
  defp project_file(relative, source \\ @source),
    do: source_file(Path.join(@root, relative), source)

  defp by_line(issues), do: Enum.sort_by(issues, & &1.line_no)

  describe "with an sgconfig.yml" do
    test "reports the matches of the config's rules" do
      issues =
        "lib/sample.ex"
        |> project_file()
        |> run_check(Check, config: @config)
        |> assert_issues(4)
        |> by_line()

      assert [io_inspect, dbg, apply, length] = issues

      assert %{
               message: "[no-io-inspect] Remove IO.inspect(user)",
               trigger: "IO.inspect(user)",
               line_no: 3,
               column: 5,
               category: :warning,
               exit_status: 16
             } = io_inspect

      assert %{message: "[no-dbg] Remove dbg calls", trigger: "dbg(user)", line_no: 4} = dbg

      assert %{
               message: "[no-apply-in-lib] Avoid apply/3 with a literal function name",
               line_no: 5
             } =
               apply

      assert %{
               message:
                 "[prefer-enum-empty] Use Enum.empty?(user.items) instead of length(user.items) == 0",
               trigger: "length(user.items) == 0",
               line_no: 7,
               column: 8
             } = length

      assert io_inspect.check == Check
      assert io_inspect.filename == Path.relative_to_cwd(Path.join(@root, "lib/sample.ex"))
    end

    test "maps rule severities to priorities" do
      priorities =
        "lib/sample.ex"
        |> project_file()
        |> run_check(Check, config: @config)
        |> Map.new(&{&1.trigger, &1.priority})

      assert priorities == %{
               # severity: warning
               "IO.inspect(user)" => Priority.to_integer(:high),
               # severity: error
               "dbg(user)" => Priority.to_integer(:higher),
               # severity: info
               "apply(Sample, :other, [user])" => Priority.to_integer(:normal),
               # severity: hint
               "length(user.items) == 0" => Priority.to_integer(:low)
             }
    end

    test "uses metadata.credo_category, else the category param" do
      categories =
        "lib/sample.ex"
        |> project_file()
        |> run_check(Check, config: @config, category: :refactor)
        |> Map.new(&{&1.trigger, {&1.category, &1.exit_status}})

      assert categories["IO.inspect(user)"] == {:refactor, 8}
      assert categories["dbg(user)"] == {:refactor, 8}
      assert categories["length(user.items) == 0"] == {:readability, 4}
    end

    test "a priority param applies to rules without metadata.credo_priority" do
      "lib/sample.ex"
      |> project_file()
      |> run_check(Check, config: @config, priority: :low, only: ["no-dbg"])
      |> assert_issue(%{trigger: "dbg(user)", priority: Priority.to_integer(:low)})
    end

    test "reports the first line of multi-line matches as trigger" do
      source = """
      defmodule Sample do
        def run(user) do
          IO.inspect(
            user
          )
        end
      end
      """

      "lib/sample.ex"
      |> project_file(source)
      |> run_check(Check, config: @config)
      |> assert_issue(%{trigger: "IO.inspect(", line_no: 3, column: 5})
    end

    test "honors ast-grep-ignore comments" do
      source = """
      defmodule Sample do
        def run(user) do
          # ast-grep-ignore: no-io-inspect
          IO.inspect(user)
          IO.inspect(user) # ast-grep-ignore
          # ast-grep-ignore: no-dbg
          IO.inspect(:reported)
        end
      end
      """

      "lib/sample.ex"
      |> project_file(source)
      |> run_check(Check, config: @config)
      |> assert_issue(%{line_no: 7, trigger: "IO.inspect(:reported)"})
    end

    test "uses the in-memory source, not the file on disk" do
      "lib/does_not_exist.ex"
      |> project_file("IO.inspect(:in_memory)")
      |> run_check(Check, config: @config)
      |> assert_issue(%{trigger: "IO.inspect(:in_memory)"})
    end
  end

  describe "rule files/ignores globs" do
    test "are matched against paths relative to the config's directory" do
      assert ["lib/sample.ex"]
             |> Enum.map(&project_file/1)
             |> run_check(Check, config: @config)
             |> apply_issue?()

      refute ["lib/generated/sample.ex"]
             |> Enum.map(&project_file/1)
             |> run_check(Check, config: @config)
             |> apply_issue?()

      refute ["test/sample_test.exs"]
             |> Enum.map(&project_file/1)
             |> run_check(Check, config: @config)
             |> apply_issue?()
    end

    test "work with absolute filenames" do
      absolute = fn relative ->
        source_file = project_file(relative)
        %{source_file | filename: Path.join(@root, relative)}
      end

      issues = run_check([absolute.("lib/sample.ex")], Check, config: @config)
      assert apply_issue?(issues)
      assert Enum.all?(issues, &(&1.filename == Path.join(@root, "lib/sample.ex")))

      refute [absolute.("lib/generated/sample.ex")]
             |> run_check(Check, config: @config)
             |> apply_issue?()
    end

    test "are relative to the current directory without a config" do
      params = [config: false, paths: [Path.join(@root, "rules/no_apply_in_lib.yml")]]

      "lib/sample.ex"
      |> source_file()
      |> run_check(Check, params)
      |> assert_issue(%{line_no: 5})

      "lib/generated/sample.ex"
      |> source_file()
      |> run_check(Check, params)
      |> refute_issues()

      "test/sample_test.exs"
      |> source_file()
      |> run_check(Check, params)
      |> refute_issues()
    end

    defp apply_issue?(issues),
      do: Enum.any?(issues, &String.starts_with?(&1.message, "[no-apply-in-lib]"))
  end

  describe "explicit rule paths" do
    test "loads rule files" do
      "lib/sample.ex"
      |> source_file()
      |> run_check(Check, config: false, paths: [Path.join(@root, "extra/no_string_to_atom.yml")])
      |> assert_issue(%{
        message: "[no-string-to-atom] String.to_atom/1 can exhaust the atom table",
        trigger: "String.to_atom(user.name)",
        line_no: 13,
        # from metadata.credo_category / credo_priority
        category: :design,
        exit_status: 2,
        priority: Priority.to_integer(:normal)
      })
    end

    test "are relative to the current directory and can be directories" do
      "lib/sample.ex"
      |> source_file()
      |> run_check(Check,
        config: false,
        paths: [Path.relative_to_cwd(Path.join(@root, "rules"))],
        utils: [Path.relative_to_cwd(Path.join(@root, "utils"))]
      )
      |> assert_issues(4)
    end

    test "are loaded in addition to the config's rules" do
      "lib/sample.ex"
      |> project_file()
      |> run_check(Check,
        config: @config,
        paths: [Path.join(@root, "extra/no_string_to_atom.yml")]
      )
      |> assert_issues(5)
    end

    test "can use utility rules" do
      "lib/sample.ex"
      |> source_file()
      |> run_check(Check,
        config: false,
        paths: [Path.join(@root, "extra/uses_util.yml")],
        utils: [Path.join(@root, "utils")]
      )
      |> assert_issue(%{message: "[no-dbg-via-util] Remove dbg calls", line_no: 4})
    end
  end

  describe "only/except" do
    test "select rules by id" do
      issues =
        "lib/sample.ex"
        |> project_file()
        |> run_check(Check, config: @config, only: ["no-dbg", "no-io-inspect"])

      assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [3, 4]

      issues =
        "lib/sample.ex"
        |> project_file()
        |> run_check(Check, config: @config, except: ["no-dbg", "no-io-inspect"])

      assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [5, 7]
    end

    test "excluding every rule reports nothing" do
      "lib/sample.ex"
      |> project_file()
      |> run_check(Check, config: @config, only: ["unknown"])
      |> refute_issues()
    end
  end

  describe "without rules" do
    test "reports nothing" do
      "lib/sample.ex"
      |> source_file()
      |> run_check(Check, config: false)
      |> refute_issues()
    end

    test "skips files of other languages" do
      "README.md"
      |> to_source_file_unparsed("IO.inspect(user)")
      |> Check.run(config: @config)
      |> refute_issues()
    end
  end

  describe "run/2" do
    test "loads the rules when they are not prepared" do
      "lib/sample.ex"
      |> project_file()
      |> Check.run(config: @config, only: ["no-dbg"])
      |> assert_issue(%{line_no: 4})
    end
  end

  describe "invalid rules" do
    test "raise with the reason" do
      params = [config: false, paths: [Path.join(@root, "invalid/unknown_language.yml")]]

      stderr =
        capture_io(:stderr, fn ->
          error =
            assert_raise AstGrep.Error, fn ->
              "lib/sample.ex" |> source_file() |> run_check(Check, params)
            end

          assert error.message =~ "AstGrep.Credo.Check could not load ast-grep rules"
          assert error.message =~ "unknown_language.yml"
          assert error.message =~ "cobol"
        end)

      assert stderr =~ "could not load ast-grep rules"
      assert stderr =~ "unknown_language.yml"
    end

    test "raise when a config cannot be read" do
      capture_io(:stderr, fn ->
        assert_raise AstGrep.Error, ~r/missing\.yml/, fn ->
          "lib/sample.ex"
          |> source_file()
          |> run_check(Check, config: Path.join(@root, "missing.yml"))
        end
      end)
    end

    test "raise on an invalid metadata.credo_category" do
      assert_raise AstGrep.Error, ~r/invalid metadata.credo_category "style"/, fn ->
        "lib/sample.ex"
        |> source_file()
        |> run_check(Check, config: false, paths: [Path.join(@root, "invalid/bad_category.yml")])
      end
    end

    test "raise on an invalid :config param" do
      assert_raise ArgumentError, ~r/invalid :config param/, fn ->
        "lib/sample.ex" |> source_file() |> run_check(Check, config: 42)
      end
    end
  end

  test "documents its params" do
    assert Check.param_defaults() == [
             config: :auto,
             paths: [],
             utils: [],
             only: nil,
             except: [],
             category: :warning
           ]

    assert Keyword.keys(Check.explanations()[:params]) ==
             [:config, :paths, :utils, :only, :except, :category]
  end

  defp to_source_file_unparsed(filename, source) do
    # Credo only parses Elixir files; build a source file for another language.
    source_file = to_source_file(source)
    %{source_file | filename: filename}
  end
end

defmodule AstGrep.Credo.CheckIntegrationTest do
  # Changes the current directory: not async.
  use Credo.Test.Case, async: false

  alias AstGrep.Credo.Check

  @moduletag :tmp_dir

  @rule """
  id: no-io-inspect
  language: elixir
  severity: warning
  message: Remove IO.inspect($A)
  rule:
    pattern: IO.inspect($A)
  """

  test "discovers the sgconfig.yml of the current directory or its parents", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "rules"))
    File.mkdir_p!(Path.join(tmp_dir, "apps/app/lib"))
    File.write!(Path.join(tmp_dir, "sgconfig.yml"), "ruleDirs: [rules]\n")
    File.write!(Path.join(tmp_dir, "rules/no_io_inspect.yml"), @rule)

    File.cd!(Path.join(tmp_dir, "apps/app"), fn ->
      "IO.inspect(:x)"
      |> to_source_file("lib/app.ex")
      |> run_check(Check)
      |> assert_issue(%{message: "[no-io-inspect] Remove IO.inspect(:x)"})

      "IO.inspect(:x)"
      |> to_source_file("lib/app.ex")
      |> run_check(Check, config: false)
      |> refute_issues()
    end)
  end

  test "reports nothing without config nor paths", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert AstGrep.Config.find(tmp_dir) == :error

      "IO.inspect(:x)"
      |> to_source_file("lib/app.ex")
      |> run_check(Check)
      |> refute_issues()
    end)
  end

  test "mix credo reports issues, honoring credo:disable comments", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "rules"))
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "sgconfig.yml"), "ruleDirs: [rules]\n")
    File.write!(Path.join(tmp_dir, "rules/no_io_inspect.yml"), @rule)

    File.write!(Path.join(tmp_dir, "lib/app.ex"), """
    defmodule App do
      def run(x) do
        IO.inspect(x)
        # credo:disable-for-next-line
        IO.inspect(:disabled)
        # credo:disable-for-next-line AstGrep.Credo.Check
        IO.inspect(:disabled_by_name)
        x
      end
    end
    """)

    File.write!(Path.join(tmp_dir, ".credo.exs"), """
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

    exec =
      File.cd!(tmp_dir, fn ->
        Credo.CLI.Output.Shell.suppress_output(fn ->
          send(self(), {:exec, Credo.run(["--strict"])})
        end)

        assert_received {:exec, exec}
        exec
      end)

    assert Credo.Execution.get_exit_status(exec) == 16

    assert [issue] = Credo.Execution.get_issues(exec)

    assert %Credo.Issue{
             check: Check,
             category: :warning,
             filename: "lib/app.ex",
             line_no: 3,
             column: 5,
             trigger: "IO.inspect(x)",
             message: "[no-io-inspect] Remove IO.inspect(x)"
           } = issue
  end
end
