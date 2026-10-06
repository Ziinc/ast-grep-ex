defmodule AstGrep.RuleSet do
  @moduledoc """
  A compiled set of ast-grep rules, ready to scan sources with
  `AstGrep.scan/3` and `AstGrep.scan_file/3`.

  Rules are [ast-grep rule configs](https://ast-grep.github.io/reference/yaml.html)
  given either as YAML (a binary that may hold several `---` separated
  documents) or as Elixir maps / keyword lists using ast-grep's key names:

      {:ok, rule_set} =
        AstGrep.RuleSet.compile(\"\"\"
        id: no-io-inspect
        language: elixir
        severity: warning
        message: Remove IO.inspect($A)
        rule:
          pattern: IO.inspect($A)
        fix: $A
        \"\"\")

      {:ok, rule_set} =
        AstGrep.RuleSet.compile(
          id: "no-io-inspect",
          language: :elixir,
          severity: :warning,
          rule: [pattern: "IO.inspect($A)"]
        )

  Rules can also be loaded from files and directories (`load/2`) or from an
  ast-grep project config (`from_config/2`).

  Global utility rules (the files of ast-grep's `utilDirs`) are passed with
  the `:utils` option and can be referenced from rules with `matches:`.

  Rules with `severity: off` are dropped at compile time.

  A rule set is backed by a NIF resource, it can be shared freely between
  processes (for example stored in `:persistent_term`) and used concurrently.
  """

  alias AstGrep.{Config, Error, Native, Paths}

  @derive {Inspect, only: [:rules, :root]}
  defstruct [:ref, :root, rules: [], sources: [], utils: []]

  @typedoc """
  A compiled rule set.

    * `:ref` - the compiled NIF resource.
    * `:rules` - the compiled rules, sorted by id.
    * `:root` - the project root that rule `files`/`ignores` globs are
      relative to, when known (set by `from_config/2` and by the `:root`
      option). `AstGrep.scan_file/3` uses it as its default root.
    * `:sources` / `:utils` - the rule and utility documents the set was
      compiled from (used by `filter/2`).
  """
  @type t :: %__MODULE__{
          ref: reference() | nil,
          root: Path.t() | nil,
          rules: [AstGrep.Rule.t()],
          sources: [source()],
          utils: [source()]
        }

  @typedoc "A YAML binary (possibly multi-document), or a single rule as a map / keyword list."
  @type source :: String.t() | map() | keyword()

  @doc """
  Compiles `rules` (a single rule source or a list of them) into a rule set.

  ## Options

    * `:utils` - global utility rules (a source or a list of sources).
    * `:root` - the project root, stored in the rule set (see `t:t/0`).

  ## Examples

      iex> {:ok, rule_set} = AstGrep.RuleSet.compile(%{id: "x", language: "elixir", rule: %{pattern: "foo"}})
      iex> AstGrep.RuleSet.rule_ids(rule_set)
      ["x"]

  """
  @spec compile(source() | [source()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def compile(rules, opts \\ []) do
    sources = wrap(rules)
    utils = wrap(Keyword.get(opts, :utils, []))

    case Native.compile_rules(sources, utils) do
      {:ok, ref} -> {:ok, build(ref, sources, utils, root(opts))}
      {:error, message} -> {:error, Error.new(message)}
    end
  end

  @doc """
  Like `compile/2` but raises `AstGrep.Error` on failure.
  """
  @spec compile!(source() | [source()], keyword()) :: t()
  def compile!(rules, opts \\ []), do: unwrap!(compile(rules, opts))

  @doc """
  Loads rules from files and directories.

  `paths` is a path or a list of paths. Directories are searched recursively
  for `*.yml` / `*.yaml` files; files are read as is. Each file may hold
  several `---` separated rules. Empty files are ignored.

  Errors name the offending file, both in the message and in the `:path`
  field of the returned `AstGrep.Error`.

  ## Options

    * `:utils` - paths (files or directories) of global utility rules.
    * `:rules` - extra inline rule sources appended to the loaded ones.
    * `:root` - directory relative paths are resolved against (default:
      the current working directory). When given, it is also stored as the
      rule set's `:root`.

  """
  @spec load(Path.t() | [Path.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(paths, opts \\ []) do
    base = Path.expand(Keyword.get(opts, :root) || File.cwd!())

    with {:ok, rule_files} <- collect(paths, base),
         {:ok, util_files} <- collect(Keyword.get(opts, :utils, []), base),
         {:ok, rule_files} <- read_all(rule_files),
         {:ok, util_files} <- read_all(util_files) do
      sources = Enum.map(rule_files, &elem(&1, 1)) ++ wrap(Keyword.get(opts, :rules, []))
      utils = Enum.map(util_files, &elem(&1, 1))

      case Native.compile_rules(sources, utils) do
        {:ok, ref} -> {:ok, build(ref, sources, utils, root(opts))}
        {:error, message} -> {:error, attribute(message, rule_files, util_files, utils)}
      end
    end
  end

  @doc """
  Like `load/2` but raises `AstGrep.Error` on failure.
  """
  @spec load!(Path.t() | [Path.t()], keyword()) :: t()
  def load!(paths, opts \\ []), do: unwrap!(load(paths, opts))

  @doc """
  Loads the rules of an ast-grep project config (`sgconfig.yml`).

  The config's `ruleDirs` and `utilDirs` are loaded with `load/2`, and the
  config's directory becomes the rule set's `:root`.

  `opts` are passed to `load/2`: `:rules` adds inline rules and `:utils`
  adds utility paths (relative to the config's directory).
  """
  @spec from_config(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_config(path \\ "sgconfig.yml", opts \\ []) do
    with {:ok, %Config{} = config} <- Config.load(path) do
      opts =
        opts
        |> Keyword.put(:root, config.root)
        |> Keyword.update(:utils, config.util_dirs, &(config.util_dirs ++ List.wrap(&1)))

      load(config.rule_dirs, opts)
    end
  end

  @doc """
  Like `from_config/2` but raises `AstGrep.Error` on failure.
  """
  @spec from_config!(Path.t(), keyword()) :: t()
  def from_config!(path \\ "sgconfig.yml", opts \\ []), do: unwrap!(from_config(path, opts))

  @doc """
  Returns the compiled rules, sorted by id.
  """
  @spec rules(t()) :: [AstGrep.Rule.t()]
  def rules(%__MODULE__{rules: rules}), do: rules

  @doc """
  Returns the ids of the compiled rules, sorted.
  """
  @spec rule_ids(t()) :: [String.t()]
  def rule_ids(%__MODULE__{rules: rules}), do: Enum.map(rules, & &1.id)

  @doc """
  Returns a new rule set holding only some of the rules.

  The selected rule documents are recompiled (with the same utility rules),
  so the returned rule set is as efficient as one compiled with only those
  rules.

  ## Options

    * `:only` - rule id or list of ids to keep.
    * `:except` - rule id or list of ids to drop.

  Unknown ids are ignored.
  """
  @spec filter(t(), keyword()) :: t()
  def filter(%__MODULE__{} = rule_set, opts) do
    only = opts |> Keyword.get(:only) |> id_set()
    except = opts |> Keyword.get(:except) |> id_set() || MapSet.new()

    keep? = fn id -> (is_nil(only) or id in only) and id not in except end

    if Enum.all?(rule_ids(rule_set), keep?) do
      rule_set
    else
      sources =
        rule_set.sources
        |> Enum.flat_map(&documents/1)
        |> Enum.filter(&keep?.(document_id(&1)))

      case Native.compile_rules(sources, rule_set.utils) do
        {:ok, ref} ->
          build(ref, sources, rule_set.utils, rule_set.root)

        {:error, message} ->
          raise Error.new("could not recompile filtered rules: #{message}")
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp build(ref, sources, utils, root) do
    %__MODULE__{ref: ref, rules: Native.rules(ref), sources: sources, utils: utils, root: root}
  end

  defp root(opts) do
    case Keyword.get(opts, :root) do
      nil -> nil
      root -> Path.expand(root)
    end
  end

  defp unwrap!({:ok, rule_set}), do: rule_set
  defp unwrap!({:error, error}), do: raise(error)

  defp wrap(nil), do: []
  defp wrap(source) when is_binary(source) or is_map(source), do: [source]

  defp wrap(list) when is_list(list) do
    if list != [] and Keyword.keyword?(list), do: [list], else: list
  end

  defp id_set(nil), do: nil
  defp id_set(ids), do: ids |> List.wrap() |> MapSet.new(&to_string/1)

  # Splits a source into its rule documents.
  defp documents(yaml) when is_binary(yaml) do
    case Native.parse_yaml(yaml) do
      {:ok, docs} -> Enum.reject(docs, &is_nil/1)
      {:error, message} -> raise Error.new("invalid rule YAML: #{message}")
    end
  end

  defp documents(rule), do: [rule]

  defp document_id(rule) when is_map(rule), do: to_string(rule["id"] || rule[:id])
  defp document_id(rule) when is_list(rule), do: to_string(rule[:id])

  # Expands `paths` into the list of rule files they designate.
  defp collect(paths, base) do
    paths
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      path = Path.expand(path, base)

      cond do
        File.dir?(path) -> {:cont, {:ok, acc ++ Paths.walk(path, &yaml_file?/1)}}
        File.regular?(path) -> {:cont, {:ok, acc ++ [path]}}
        true -> {:halt, {:error, Error.for_file(path, "no such file or directory")}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.uniq(files)}
      error -> error
    end
  end

  defp yaml_file?(path), do: Path.extname(path) in [".yml", ".yaml"]

  # Reads files, returning `{path, content}` pairs. Files without any YAML
  # document are skipped, and YAML syntax errors are reported per file.
  defp read_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, content} <- read(path),
           {:ok, docs} <- parse(path, content) do
        if Enum.all?(docs, &is_nil/1),
          do: {:cont, {:ok, acc}},
          else: {:cont, {:ok, [{path, content} | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, Error.for_file(path, :file.format_error(reason) |> to_string())}
    end
  end

  defp parse(path, content) do
    case Native.parse_yaml(content) do
      {:ok, docs} -> {:ok, docs}
      {:error, message} -> {:error, Error.for_file(path, "invalid YAML: #{message}")}
    end
  end

  # Attributes a compilation error of the whole set to the file causing it,
  # by compiling the files one at a time.
  defp attribute("invalid utility rule `" <> rest = message, _rule_files, util_files, _utils) do
    [id | _] = String.split(rest, "`", parts: 2)

    Enum.find_value(util_files, Error.new(message), fn {path, content} ->
      if Enum.any?(documents(content), &(document_id(&1) == id)),
        do: Error.for_file(path, message)
    end)
  end

  defp attribute("invalid utility rules" <> _ = message, _rule_files, util_files, _utils) do
    Enum.find_value(util_files, Error.new(message), fn {path, content} ->
      case Native.compile_rules([], [content]) do
        {:ok, _} -> nil
        {:error, _} -> Error.for_file(path, message)
      end
    end)
  end

  # A duplicate id is attributed to the (first) file redefining it.
  defp attribute("duplicate rule id `" <> rest = message, rule_files, _util_files, _utils) do
    [id | _] = String.split(rest, "`", parts: 2)

    Enum.reduce_while(rule_files, {nil, Error.new(message)}, fn {path, content}, {first, error} ->
      count = content |> documents() |> Enum.count(&(document_id(&1) == id))

      cond do
        count == 0 ->
          {:cont, {first, error}}

        first != nil ->
          message = "#{message} (already defined in #{Path.relative_to_cwd(first)})"
          {:halt, {first, Error.for_file(path, message)}}

        count > 1 ->
          {:halt, {path, Error.for_file(path, message)}}

        true ->
          {:cont, {path, error}}
      end
    end)
    |> elem(1)
  end

  defp attribute(message, rule_files, _util_files, utils) do
    Enum.find_value(rule_files, Error.new(message), fn {path, content} ->
      case Native.compile_rules([content], utils) do
        {:ok, _} -> nil
        {:error, file_message} -> Error.for_file(path, file_message)
      end
    end)
  end
end
