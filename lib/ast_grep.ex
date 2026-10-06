defmodule AstGrep do
  @moduledoc """
  Structural search, linting and rewriting of source code with
  [ast-grep](https://ast-grep.github.io).

  ## Ad-hoc search and replace

  `find/3` matches a pattern (or an ast-grep rule object) against a source
  string. Metavariables such as `$A` capture a single node and `$$$ARGS`
  captures a list of nodes:

      iex> {:ok, [match]} = AstGrep.find("IO.inspect(user, label: :x)", "IO.inspect($A, $$$OPTS)", language: :elixir)
      iex> match.meta_variables
      %{"A" => "user", "OPTS" => ["label: :x"]}

  `replace/4` rewrites every match with a fix template:

      iex> AstGrep.replace("IO.inspect(user)", "IO.inspect($A)", "dbg($A)", language: :elixir)
      {:ok, "dbg(user)"}

  Rule objects can be given as maps or keyword lists using ast-grep's rule
  keys (`kind`, `pattern`, `has`, `inside`, `all`, `any`, `not`, `matches`,
  `regex`, `stopBy`, ...):

      AstGrep.find(source, [kind: "call", has: [pattern: "IO", stopBy: "end"]], language: :elixir)

  ## Linting with rule sets

  Rules are ast-grep [rule configs](https://ast-grep.github.io/reference/yaml.html),
  compiled once into an `AstGrep.RuleSet`:

      rule_set = AstGrep.RuleSet.compile!(\"\"\"
      id: no-io-inspect
      language: elixir
      severity: warning
      message: Remove IO.inspect($A)
      rule:
        pattern: IO.inspect($A)
      fix: $A
      \"\"\")

      {:ok, matches} = AstGrep.scan(source, rule_set, path: "lib/my_app.ex")
      new_source = AstGrep.apply_fixes(source, matches)

  Rule sets can be loaded from YAML files with `AstGrep.RuleSet.load/2`, or
  from an ast-grep project (`sgconfig.yml`) with
  `AstGrep.RuleSet.from_config/2`. `scan/3` honors `files`/`ignores` globs
  and `ast-grep-ignore` suppression comments.

  The `mix ast_grep.scan` task scans a project from the command line.

  ## Languages

  Functions taking a `:language` accept atoms or strings, including aliases
  such as `:ex`, `"Elixir"` or `"js"`. See `languages/0`.
  """

  alias AstGrep.{Error, Fix, Match, Native, Paths, RuleSet}

  @typedoc "A language name or alias, e.g. `:elixir`, `\"elixir\"`, `:ex`."
  @type language :: atom() | String.t()

  @typedoc "A pattern string, or an ast-grep rule object as a map or keyword list."
  @type pattern_or_rule :: String.t() | map() | keyword()

  @doc """
  Lists the supported languages (normalized names).

      iex> "elixir" in AstGrep.languages()
      true

  """
  @spec languages() :: [String.t()]
  def languages, do: Native.languages()

  @doc """
  Normalizes a language name or alias.

      iex> AstGrep.normalize_language(:ex)
      {:ok, "elixir"}

      iex> {:error, %AstGrep.Error{}} = AstGrep.normalize_language("cobol")

  """
  @spec normalize_language(language()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalize_language(language) when is_atom(language) and not is_nil(language),
    do: normalize_language(Atom.to_string(language))

  def normalize_language(language) when is_binary(language) do
    case Native.normalize_language(language) do
      {:ok, language} -> {:ok, language}
      {:error, message} -> {:error, Error.new("unknown language: #{message}")}
    end
  end

  def normalize_language(other),
    do: {:error, Error.new("invalid language: #{inspect(other)}")}

  @doc """
  Infers the language of a file from its extension, or returns `nil`.

      iex> AstGrep.language_for_path("lib/foo.ex")
      "elixir"

  """
  @spec language_for_path(Path.t()) :: String.t() | nil
  def language_for_path(path), do: Native.language_for_path(to_string(path))

  @doc """
  Scans `source` with the rules of `rule_set`.

  Only rules for the source's language are run. A rule with `files` or
  `ignores` globs runs only when `:path` is given and matches its globs. Nodes
  preceded by (or on the same line as) an `ast-grep-ignore` comment are
  skipped. Matches are sorted by position.

  ## Options

    * `:language` - the language of `source`. Inferred from `:path` when not
      given.
    * `:path` - the path of the source, relative to the project root (e.g.
      `"lib/my_app.ex"`), used to match rule globs.

  """
  @spec scan(String.t(), RuleSet.t(), keyword()) :: {:ok, [Match.t()]} | {:error, Error.t()}
  def scan(source, %RuleSet{ref: ref}, opts \\ []) when is_binary(source) do
    path = opts |> Keyword.get(:path) |> clean_path()

    with {:ok, language} <- optional_language(opts) do
      case Native.scan(ref, source, language, path) do
        {:ok, matches} -> {:ok, matches}
        {:error, message} -> {:error, Error.new(message, path)}
      end
    end
  end

  @doc """
  Like `scan/3` but raises `AstGrep.Error` on failure.
  """
  @spec scan!(String.t(), RuleSet.t(), keyword()) :: [Match.t()]
  def scan!(source, rule_set, opts \\ []), do: unwrap!(scan(source, rule_set, opts))

  @doc """
  Reads the file at `path` and scans it with `scan/3`.

  The path used for rule globs is `path` relative to the project root when
  the file is inside it (otherwise `path` itself).

  ## Options

    * `:root` - the project root. Defaults to the rule set's `:root` (see
      `AstGrep.RuleSet`) or else the current working directory.
    * `:language` - overrides the language inferred from the file extension.

  """
  @spec scan_file(Path.t(), RuleSet.t(), keyword()) :: {:ok, [Match.t()]} | {:error, Error.t()}
  def scan_file(path, %RuleSet{} = rule_set, opts \\ []) do
    root = Keyword.get(opts, :root) || rule_set.root || File.cwd!()
    relative = Paths.relative_to(path, root) || path

    case File.read(path) do
      {:ok, source} ->
        case scan(source, rule_set, language: Keyword.get(opts, :language), path: relative) do
          {:ok, matches} -> {:ok, matches}
          {:error, error} -> {:error, Error.for_file(path, error.message)}
        end

      {:error, reason} ->
        {:error, Error.for_file(path, to_string(:file.format_error(reason)))}
    end
  end

  @doc """
  Like `scan_file/3` but raises `AstGrep.Error` on failure.
  """
  @spec scan_file!(Path.t(), RuleSet.t(), keyword()) :: [Match.t()]
  def scan_file!(path, rule_set, opts \\ []), do: unwrap!(scan_file(path, rule_set, opts))

  @doc """
  Finds all nodes of `source` matching a pattern or rule object.

  `pattern_or_rule` is either a pattern string (e.g. `"IO.inspect($A)"`) or
  an ast-grep rule object as a map or keyword list (e.g.
  `%{kind: "call", has: %{pattern: "IO"}}`).

  Suppression comments are not honored. The returned matches have
  `rule_id: "find"`. Nested matches are all returned.

  ## Options

    * `:language` - the language of `source` (required unless `:path` is
      given).
    * `:path` - a file path to infer the language from.
    * `:constraints` - ast-grep `constraints` on metavariables, e.g.
      `%{A: %{kind: "identifier"}}`.
    * `:utils` - local utility rules (`utils`), a map of id to rule.
    * `:transform` - ast-grep `transform` definitions.
    * `:fix` - an ast-grep fix (see `replace/4`); the matches then carry an
      `AstGrep.Fix` that can be applied with `apply_fixes/2`.

  ## Examples

      iex> {:ok, matches} = AstGrep.find("foo(1)\\nbar(2)\\nfoo(3)", "foo($A)", language: :elixir)
      iex> Enum.map(matches, & &1.meta_variables["A"])
      ["1", "3"]

  """
  @spec find(String.t(), pattern_or_rule(), keyword()) ::
          {:ok, [Match.t()]} | {:error, Error.t()}
  def find(source, pattern_or_rule, opts \\ []) when is_binary(source) do
    with {:ok, language} <- required_language(opts),
         {:ok, rule_set} <- RuleSet.compile(find_rule(language, pattern_or_rule, opts)) do
      case Native.find_all(rule_set.ref, source, language, nil) do
        {:ok, matches} -> {:ok, matches}
        {:error, message} -> {:error, Error.new(message)}
      end
    end
  end

  @doc """
  Like `find/3` but raises `AstGrep.Error` on failure.
  """
  @spec find!(String.t(), pattern_or_rule(), keyword()) :: [Match.t()]
  def find!(source, pattern_or_rule, opts \\ []),
    do: unwrap!(find(source, pattern_or_rule, opts))

  @doc """
  Replaces every match of `pattern_or_rule` in `source` using `fix`.

  `fix` is an ast-grep fix: a template string that can reference
  metavariables (`"dbg($A)"`), or a fix config map (`template`,
  `expandStart`, `expandEnd`). Takes the same options as `find/3`. When
  matches overlap, the first one (outermost) wins, see `apply_fixes/2`.

      iex> AstGrep.replace("a = foo(1, 2)", "foo($$$ARGS)", "bar($$$ARGS)", language: "elixir")
      {:ok, "a = bar(1, 2)"}

  """
  @spec replace(String.t(), pattern_or_rule(), String.t() | map() | keyword(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def replace(source, pattern_or_rule, fix, opts \\ []) do
    with {:ok, matches} <- find(source, pattern_or_rule, Keyword.put(opts, :fix, fix)) do
      {:ok, apply_fixes(source, matches)}
    end
  end

  @doc """
  Like `replace/4` but raises `AstGrep.Error` on failure.
  """
  @spec replace!(String.t(), pattern_or_rule(), String.t() | map() | keyword(), keyword()) ::
          String.t()
  def replace!(source, pattern_or_rule, fix, opts \\ []),
    do: unwrap!(replace(source, pattern_or_rule, fix, opts))

  @doc """
  Applies the fixes of `matches` to `source` and returns the new source.

  Matches without a fix are ignored. Fixes are applied in order of their
  start offset; a fix overlapping an already applied one is skipped (the
  first one wins), so running a scan and fix again may be needed to fix
  everything. `matches` may also contain `AstGrep.Fix` structs.
  """
  @spec apply_fixes(String.t(), [Match.t() | Fix.t()]) :: String.t()
  def apply_fixes(source, matches) when is_binary(source) do
    source |> fix_source(matches) |> elem(0)
  end

  @doc false
  # Like `apply_fixes/2`, also returning the number of fixes applied.
  @spec fix_source(String.t(), [Match.t() | Fix.t()]) :: {String.t(), non_neg_integer()}
  def fix_source(source, matches) do
    fixes =
      matches
      |> Enum.map(&fix_of/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.range.start.offset)

    {iodata, position, count} =
      Enum.reduce(fixes, {[], 0, 0}, fn %Fix{range: range} = fix, {acc, position, count} ->
        start = range.start.offset

        if start < position do
          {acc, position, count}
        else
          acc = [acc, binary_part(source, position, start - position), fix.replacement]
          {acc, range.end.offset, count + 1}
        end
      end)

    rest = binary_part(source, position, byte_size(source) - position)
    {IO.iodata_to_binary([iodata, rest]), count}
  end

  @doc """
  Returns the syntax tree of `source`, useful when writing rules (to find
  node `kind`s and `field` names).

      {:ok, tree} = AstGrep.dump_tree("foo(1)", :elixir)
      IO.puts(tree)
      # source (1,1)-(1,7)
      #   call (1,1)-(1,7)
      #     target: identifier (1,1)-(1,4) "foo"
      #     arguments (1,4)-(1,7)
      #       integer (1,5)-(1,6) "1"

  """
  @spec dump_tree(String.t(), language()) :: {:ok, String.t()} | {:error, Error.t()}
  def dump_tree(source, language) when is_binary(source) do
    with {:ok, language} <- normalize_language(language) do
      case Native.dump_tree(source, language) do
        {:ok, tree} -> {:ok, tree}
        {:error, message} -> {:error, Error.new(message)}
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp find_rule(language, pattern_or_rule, opts) do
    rule =
      if is_binary(pattern_or_rule), do: %{"pattern" => pattern_or_rule}, else: pattern_or_rule

    [constraints: "constraints", utils: "utils", transform: "transform", fix: "fix"]
    |> Enum.reduce(%{"id" => "find", "language" => language, "rule" => rule}, fn {opt, key},
                                                                                 config ->
      case Keyword.get(opts, opt) do
        nil -> config
        value -> Map.put(config, key, value)
      end
    end)
  end

  defp optional_language(opts) do
    case Keyword.get(opts, :language) do
      nil -> {:ok, nil}
      language -> normalize_language(language)
    end
  end

  defp required_language(opts) do
    case {Keyword.get(opts, :language), Keyword.get(opts, :path)} do
      {nil, nil} ->
        {:error, Error.new("the :language option is required (or a :path to infer it from)")}

      {nil, path} ->
        case language_for_path(path) do
          nil -> {:error, Error.new("cannot infer language from path `#{path}`", path)}
          language -> {:ok, language}
        end

      {language, _path} ->
        normalize_language(language)
    end
  end

  defp clean_path(nil), do: nil
  defp clean_path("./" <> path), do: clean_path(path)
  defp clean_path(path), do: to_string(path)

  defp fix_of(%Match{fix: fix}), do: fix
  defp fix_of(%Fix{} = fix), do: fix

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end
