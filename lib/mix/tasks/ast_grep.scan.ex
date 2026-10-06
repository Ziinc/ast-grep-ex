defmodule Mix.Tasks.AstGrep.Scan do
  @shortdoc "Scans source files with ast-grep rules"

  @moduledoc """
  Scans source files with ast-grep rules and reports the matches.

      $ mix ast_grep.scan [PATHS...] [--config sgconfig.yml] [--rule PATH...] [--fix]

  Rules come from an ast-grep project config (`sgconfig.yml`: its `ruleDirs`
  and `utilDirs`) and from `--rule` paths. Without `--config`, the nearest
  `sgconfig.yml`/`sgconfig.yaml` in the current directory or its parents is
  used, if any.

  `PATHS` are the files and directories to scan, defaulting to the project
  root (the config's directory, or else the current directory). Directories
  are walked recursively, skipping `_build`, `deps`, `.git`, `node_modules`
  and `.elixir_ls`; only files whose extension maps to the language of at
  least one rule are scanned. Rule `files`/`ignores` globs are matched
  against paths relative to the project root.

  Each match is printed as:

      lib/my_app.ex:12:5: warning[no-io-inspect] Remove IO.inspect(user)
          The note of the rule, if any.

  The task exits with a non-zero status when a match with severity `error`
  is found (or when a file cannot be scanned).

  ## Options

    * `--config PATH` - the ast-grep project config to use.
    * `--no-config` - do not look for a project config.
    * `--rule PATH` - a rule file or a directory of rule files (`*.yml`,
      `*.yaml`). Can be given several times. Used in addition to the rules
      of the config, whose utility rules (`utilDirs`) are available to them.
    * `--fix` - apply the rules' fixes to the files in place. The files are
      then scanned again and only the remaining matches are reported.

  """

  use Mix.Task

  alias AstGrep.{Config, Match, Paths, RuleSet}

  @switches [config: :string, no_config: :boolean, rule: :keep, fix: :boolean]

  @severities [:error, :warning, :info, :hint]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")

    {opts, paths} =
      case OptionParser.parse(args, strict: @switches) do
        {opts, paths, []} -> {opts, paths}
        {_, _, invalid} -> Mix.raise("Invalid options: #{inspect(invalid)}")
      end

    config = config(opts)
    root = if config, do: config.root, else: File.cwd!()
    rule_set = rule_set(config, opts, root)
    files = files(paths, root, rule_set)

    results = scan(files, rule_set, root)

    results =
      if opts[:fix] do
        fix(results, rule_set, root)
      else
        results
      end

    report(results, length(files))
  end

  # -- configuration ----------------------------------------------------------

  defp config(opts) do
    cond do
      path = opts[:config] ->
        load_config(path)

      opts[:no_config] ->
        nil

      true ->
        case Config.find() do
          {:ok, path} -> load_config(path)
          :error -> nil
        end
    end
  end

  defp load_config(path) do
    case Config.load(path) do
      {:ok, config} -> config
      {:error, error} -> Mix.raise(error.message)
    end
  end

  defp rule_set(config, opts, root) do
    rule_paths =
      if(config, do: config.rule_dirs, else: []) ++
        Enum.map(Keyword.get_values(opts, :rule), &Path.expand/1)

    if rule_paths == [] do
      Mix.raise("No rules to scan with. Pass --rule PATH or create an sgconfig.yml.")
    end

    utils = if config, do: config.util_dirs, else: []

    case RuleSet.load(rule_paths, utils: utils, root: root) do
      {:ok, rule_set} -> rule_set
      {:error, error} -> Mix.raise("Could not load rules: " <> error.message)
    end
  end

  defp files(paths, root, rule_set) do
    languages = rule_set |> RuleSet.rules() |> MapSet.new(& &1.language)
    scannable? = fn path -> AstGrep.language_for_path(path) in languages end

    paths
    |> case do
      [] -> [root]
      paths -> Enum.map(paths, &Path.expand/1)
    end
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) ->
          Paths.walk(path, scannable?, Paths.default_skip_dirs())

        File.regular?(path) ->
          if AstGrep.language_for_path(path) do
            [path]
          else
            Mix.shell().info("Skipping #{Paths.display(path)}: unknown language")
            []
          end

        true ->
          Mix.raise("No such file or directory: #{Paths.display(path)}")
      end
    end)
    |> Enum.uniq()
  end

  # -- scanning ---------------------------------------------------------------

  defp scan(files, rule_set, root) do
    files
    |> Task.async_stream(&{&1, AstGrep.scan_file(&1, rule_set, root: root)},
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp fix(results, rule_set, root) do
    fixed =
      results
      |> Task.async_stream(&fix_file/1, ordered: true, timeout: :infinity)
      |> Enum.flat_map(fn
        {:ok, {_path, 0}} -> []
        {:ok, {path, count}} -> [{path, count}]
      end)

    total = fixed |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    Mix.shell().info(
      "Applied #{pluralize(total, "fix", "fixes")} to #{pluralize(length(fixed), "file")}."
    )

    fixed_paths = MapSet.new(fixed, &elem(&1, 0))
    rescanned = fixed_paths |> MapSet.to_list() |> scan(rule_set, root) |> Map.new()

    Enum.map(results, fn {path, result} ->
      {path, Map.get(rescanned, path, result)}
    end)
  end

  defp fix_file({path, {:ok, matches}}) do
    if Enum.any?(matches, & &1.fix) do
      source = File.read!(path)
      {new_source, count} = AstGrep.fix_source(source, matches)
      if new_source != source, do: File.write!(path, new_source)
      {path, count}
    else
      {path, 0}
    end
  end

  defp fix_file({path, {:error, _}}), do: {path, 0}

  # -- reporting --------------------------------------------------------------

  defp report(results, file_count) do
    shell = Mix.shell()

    {matches, failures} =
      Enum.reduce(results, {[], 0}, fn
        {path, {:ok, file_matches}}, {acc, failures} ->
          Enum.each(file_matches, &print_match(path, &1))
          {Enum.reverse(file_matches, acc), failures}

        {_path, {:error, error}}, {acc, failures} ->
          shell.error("error: " <> error.message)
          {acc, failures + 1}
      end)

    counts = Enum.frequencies_by(matches, & &1.severity)

    if matches == [] do
      shell.info("No matches found in #{pluralize(file_count, "file")}.")
    else
      details =
        @severities
        |> Enum.filter(&Map.has_key?(counts, &1))
        |> Enum.map_join(", ", &pluralize(counts[&1], Atom.to_string(&1)))

      shell.info(
        "Found #{pluralize(length(matches), "match", "matches")} (#{details}) " <>
          "in #{pluralize(file_count, "file")}."
      )
    end

    errors = Map.get(counts, :error, 0)

    cond do
      errors > 0 -> Mix.raise("ast-grep found #{pluralize(errors, "error")}")
      failures > 0 -> Mix.raise("#{pluralize(failures, "file")} could not be scanned")
      true -> :ok
    end
  end

  defp print_match(path, %Match{} = match) do
    %{line: line, column: column} = match.range.start

    header =
      "#{Paths.display(path)}:#{line}:#{column}: " <>
        "#{match.severity}[#{match.rule_id}] #{match.message}"

    note =
      case match.note do
        nil -> ""
        note -> "\n" <> (note |> String.trim_trailing() |> indent())
      end

    if match.severity == :error do
      Mix.shell().error(header <> note)
    else
      Mix.shell().info(header <> note)
    end
  end

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end

  defp pluralize(count, singular, plural \\ nil)
  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, singular, plural), do: "#{count} #{plural || singular <> "s"}"
end
