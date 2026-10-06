defmodule AstGrep.Config do
  @moduledoc """
  An ast-grep project configuration (`sgconfig.yml`).

  Only the keys relevant to loading rules are read:

      ruleDirs:
        - rules
      utilDirs:
        - utils

  Directories are resolved relative to the directory holding the config file,
  which becomes the project `:root`. Rule `files`/`ignores` globs are matched
  against paths relative to this root.

  Use `AstGrep.RuleSet.from_config/2` to load the rules of a config.
  """

  alias AstGrep.Error

  defstruct [:path, :root, rule_dirs: [], util_dirs: []]

  @type t :: %__MODULE__{
          path: Path.t(),
          root: Path.t(),
          rule_dirs: [Path.t()],
          util_dirs: [Path.t()]
        }

  @config_names ["sgconfig.yml", "sgconfig.yaml"]

  @doc """
  Loads the config file at `path` (relative paths are expanded against the
  current working directory).

  Returns `{:error, %AstGrep.Error{}}` when the file cannot be read, is not
  valid YAML, or `ruleDirs`/`utilDirs` are not strings or lists of strings.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(path \\ "sgconfig.yml") do
    path = Path.expand(path)
    root = Path.dirname(path)

    with {:ok, content} <- read(path),
         {:ok, doc} <- parse(path, content),
         {:ok, rule_dirs} <- dirs(path, root, doc, "ruleDirs"),
         {:ok, util_dirs} <- dirs(path, root, doc, "utilDirs") do
      {:ok, %__MODULE__{path: path, root: root, rule_dirs: rule_dirs, util_dirs: util_dirs}}
    end
  end

  @doc """
  Like `load/1` but raises `AstGrep.Error` on failure.
  """
  @spec load!(Path.t()) :: t()
  def load!(path \\ "sgconfig.yml") do
    case load(path) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Searches `start_dir` and then each of its parent directories for
  `sgconfig.yml` (or `sgconfig.yaml`).

  Returns `{:ok, absolute_path}` for the nearest one, or `:error`.
  """
  @spec find(Path.t()) :: {:ok, Path.t()} | :error
  def find(start_dir \\ File.cwd!()) do
    start_dir |> Path.expand() |> do_find()
  end

  defp do_find(dir) do
    found =
      @config_names
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.find(&File.regular?/1)

    parent = Path.dirname(dir)

    cond do
      found -> {:ok, found}
      parent == dir -> :error
      true -> do_find(parent)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, Error.for_file(path, "cannot read config: #{:file.format_error(reason)}")}
    end
  end

  defp parse(path, content) do
    case AstGrep.Native.parse_yaml(content) do
      {:ok, [doc | _]} when is_map(doc) -> {:ok, doc}
      {:ok, [nil]} -> {:ok, %{}}
      {:ok, []} -> {:ok, %{}}
      {:ok, _} -> {:error, Error.for_file(path, "config must be a YAML mapping")}
      {:error, message} -> {:error, Error.for_file(path, "invalid config YAML: #{message}")}
    end
  end

  defp dirs(path, root, doc, key) do
    case Map.get(doc, key) do
      nil ->
        {:ok, []}

      dir when is_binary(dir) ->
        {:ok, [Path.expand(dir, root)]}

      dirs when is_list(dirs) ->
        if Enum.all?(dirs, &is_binary/1) do
          {:ok, Enum.map(dirs, &Path.expand(&1, root))}
        else
          {:error, Error.for_file(path, "`#{key}` must be a list of strings")}
        end

      _other ->
        {:error, Error.for_file(path, "`#{key}` must be a list of strings")}
    end
  end
end
