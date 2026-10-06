defmodule AstGrep.Paths do
  @moduledoc false
  # File-system helpers shared by `AstGrep.RuleSet` and `mix ast_grep.scan`.

  @default_skip_dirs ~w(_build deps .git node_modules .elixir_ls)

  @doc """
  Directory names skipped when walking source directories.
  """
  @spec default_skip_dirs() :: [String.t()]
  def default_skip_dirs, do: @default_skip_dirs

  @doc """
  Recursively lists the regular files under `dir` (sorted) for which
  `keep_file?` returns true, not descending into directories whose base name
  is in `skip_dirs`.
  """
  @spec walk(Path.t(), (Path.t() -> boolean()), [String.t()]) :: [Path.t()]
  def walk(dir, keep_file?, skip_dirs \\ []) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) ->
              if entry in skip_dirs, do: [], else: walk(path, keep_file?, skip_dirs)

            File.regular?(path) and keep_file?.(path) ->
              [path]

            true ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns `path` relative to `root` when it is inside `root`, else `nil`.
  Both paths are expanded first.
  """
  @spec relative_to(Path.t(), Path.t()) :: Path.t() | nil
  def relative_to(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)

    case Path.relative_to(path, root) do
      ^path -> nil
      relative -> relative
    end
  end

  @doc """
  The path used for display: relative to the current directory when inside
  it, otherwise unchanged.
  """
  @spec display(Path.t()) :: Path.t()
  def display(path), do: Path.relative_to_cwd(path)
end
