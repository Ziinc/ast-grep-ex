defmodule Mix.Tasks.AstGrep.ScanTest do
  # Changes the current directory and the Mix shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.AstGrep.Scan

  @fixture Path.expand("../../fixtures/project", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ast_grep_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(@fixture, dir)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp run_task(dir, args) do
    File.cd!(dir, fn ->
      try do
        Scan.run(args)
        :ok
      rescue
        error in Mix.Error -> {:error, error.message}
      end
    end)
  end

  defp output do
    receive_output([])
  end

  defp receive_output(acc) do
    receive do
      {:mix_shell, kind, [message]} when kind in [:info, :error] ->
        receive_output([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "reports matches of the nearest config and fails on errors", %{dir: dir} do
    assert {:error, "ast-grep found 1 error"} = run_task(dir, [])

    assert output() == """
           lib/example.ex:3:5: warning[no-io-inspect] Remove IO.inspect(user)
               IO.inspect/1 calls are debugging leftovers.
           lib/example.ex:4:5: error[no-dbg] Remove dbg calls
           lib/example.ex:5:5: info[no-apply-in-lib] Avoid apply/3 with a literal function name
           lib/example.ex:7:8: hint[prefer-enum-empty] Use Enum.empty?(user.items) instead of length(user.items) == 0
           scripts/script.exs:2:1: warning[no-io-inspect] Remove IO.inspect(:script)
               IO.inspect/1 calls are debugging leftovers.
           Found 5 matches (1 error, 2 warnings, 1 info, 1 hint) in 3 files.\
           """
  end

  test "finds the config from a subdirectory and scans given paths", %{dir: dir} do
    assert :ok = run_task(Path.join(dir, "scripts"), ["script.exs"])

    assert output() == """
           script.exs:2:1: warning[no-io-inspect] Remove IO.inspect(:script)
               IO.inspect/1 calls are debugging leftovers.
           Found 1 match (1 warning) in 1 file.\
           """
  end

  test "uses --rule paths without a config", %{dir: dir} do
    File.rm!(Path.join(dir, "sgconfig.yml"))

    assert :ok = run_task(dir, ["--rule", "rules/style.yaml", "--rule", "rules/no_apply.yml"])
    out = output()
    assert out =~ "lib/example.ex:5:5: info[no-apply-in-lib]"
    assert out =~ "lib/example.ex:7:8: hint[prefer-enum-empty]"
    assert out =~ "Found 2 matches (1 info, 1 hint) in 3 files."

    assert {:error, message} = run_task(dir, ["--no-config"])
    assert message =~ "No rules to scan with"
  end

  test "uses an explicit --config", %{dir: dir} do
    config = Path.join(dir, "sgconfig.yml")

    File.cd!(System.tmp_dir!(), fn ->
      try do
        Scan.run(["--config", config, Path.join(dir, "lib/generated")])
      rescue
        error in Mix.Error -> flunk("unexpected error: #{error.message}")
      end
    end)

    assert output() =~ "No matches found in 1 file."
  end

  test "--fix applies fixes and reports the remaining matches", %{dir: dir} do
    assert {:error, "ast-grep found 1 error"} = run_task(dir, ["--fix"])

    out = output()
    assert out =~ "Applied 3 fixes to 2 files."
    refute out =~ "no-io-inspect"
    refute out =~ "prefer-enum-empty"
    assert out =~ "lib/example.ex:4:5: error[no-dbg] Remove dbg calls"
    assert out =~ "Found 2 matches (1 error, 1 info) in 3 files."

    example = File.read!(Path.join(dir, "lib/example.ex"))
    assert example =~ "    user\n    dbg(user)"
    assert example =~ "if Enum.empty?(user.items) do"
    assert example =~ "IO.inspect(:suppressed)"
    assert File.read!(Path.join(dir, "scripts/script.exs")) =~ "\n:script\n"
  end

  test "--fix exits successfully when no errors remain", %{dir: dir} do
    assert :ok = run_task(dir, ["--no-config", "--rule", "rules/no_io_inspect.yml", "--fix"])

    out = output()
    assert out =~ "Applied 2 fixes to 2 files."
    assert out =~ "No matches found in 3 files."
  end

  test "reports rule loading errors", %{dir: dir} do
    File.write!(Path.join(dir, "rules/broken.yml"), "id: broken\nrule: [\n")

    assert {:error, message} = run_task(dir, [])
    assert message =~ "Could not load rules"
    assert message =~ "broken.yml"
  end

  test "rejects invalid options and missing paths", %{dir: dir} do
    assert {:error, message} = run_task(dir, ["--bogus"])
    assert message =~ "Invalid options"

    assert {:error, message} = run_task(dir, ["missing"])
    assert message =~ "No such file or directory: missing"
  end
end
