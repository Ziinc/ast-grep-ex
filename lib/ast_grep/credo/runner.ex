if Code.ensure_loaded?(Credo.Check) do
  defmodule AstGrep.Credo.Runner do
    @moduledoc false
    # Shared implementation of `AstGrep.Credo.Check` and the checks defined with
    # `AstGrep.Credo.Rule`: scans a `Credo.SourceFile` with a compiled rule set
    # and turns the `AstGrep.Match`es into `Credo.Issue`s.

    alias AstGrep.{Error, Match, Paths, Rule, RuleSet}
    alias Credo.{Issue, IssueMeta, Priority, SourceFile}

    # The params key under which a prepared rule set is passed from
    # `run_on_all_source_files/3` to `run/2`.
    @params_key :__ast_grep_rule_set__

    @categories ~w(consistency design readability refactor warning)a
    @priorities ~w(higher high normal low ignore)a

    @severity_priorities %{error: :higher, warning: :high, info: :normal, hint: :low}

    defmodule Prepared do
      @moduledoc false
      # A rule set ready to be run by a check, computed once per Credo run.
      #
      #   * `:rule_set` - the compiled `AstGrep.RuleSet`.
      #   * `:root` - absolute directory rule globs are relative to.
      #   * `:languages` - languages having at least one rule.
      #   * `:issue_opts` - per rule id, the `:category` and `:priority`
      #     (integer) of its issues.
      #   * `:prefix_rule_id?` - whether to prefix messages with `[rule-id]`.
      defstruct [
        :rule_set,
        :root,
        languages: MapSet.new(),
        issue_opts: %{},
        prefix_rule_id?: true
      ]
    end

    @doc "The params key holding the `Prepared` rule set."
    def params_key, do: @params_key

    @doc """
    Prepares `rule_set` for a check.

    ## Options

      * `:category` - the category of the issues (required).
      * `:priority` - the priority of the issues (a name or an integer). When
        `nil`, it is derived from each rule's severity.
      * `:metadata?` - whether the rules' `metadata` (`credo_category`,
        `credo_priority`) override `:category` and `:priority`.
      * `:prefix_rule_id?` - prefix messages with `[rule-id]`.
      * `:root` - the root rule globs are relative to (defaults to the rule
        set's root, then the current working directory).
    """
    def prepare(%RuleSet{} = rule_set, opts) do
      metadata? = Keyword.get(opts, :metadata?, true)
      rules = RuleSet.rules(rule_set)

      issue_opts =
        Map.new(rules, fn rule ->
          category =
            (metadata? && metadata_category!(rule)) || Keyword.fetch!(opts, :category)

          priority =
            (metadata? && metadata_priority!(rule)) || Keyword.get(opts, :priority) ||
              severity_priority(rule.severity)

          {rule.id, %{category: category, priority: Priority.to_integer(priority)}}
        end)

      %Prepared{
        rule_set: rule_set,
        root: Path.expand(Keyword.get(opts, :root) || rule_set.root || File.cwd!()),
        languages: MapSet.new(rules, & &1.language),
        issue_opts: issue_opts,
        prefix_rule_id?: Keyword.get(opts, :prefix_rule_id?, true)
      }
    end

    @doc """
    Returns the issues found by the prepared rule set in `source_file`.

    Files whose language cannot be inferred from their name, or with no rule
    for their language, are skipped. Raises `AstGrep.Error` when the scan
    fails.
    """
    def issues(%SourceFile{} = source_file, %Prepared{} = prepared, params, check) do
      filename = source_file.filename

      with language when is_binary(language) <- AstGrep.language_for_path(filename),
           true <- MapSet.member?(prepared.languages, language) do
        source = SourceFile.source(source_file)
        path = relative_path(filename, prepared.root)

        case AstGrep.scan(source, prepared.rule_set, path: path, language: language) do
          {:ok, matches} ->
            issue_meta = IssueMeta.for(source_file, params)
            Enum.map(matches, &to_issue(&1, issue_meta, prepared, check))

          {:error, %Error{} = error} ->
            raise Error.new("could not scan #{filename}: #{error.message}", filename)
        end
      else
        _ -> []
      end
    end

    @doc """
    Returns `filename` relative to `root` (both expanded against the current
    working directory) when it is inside `root`, else `filename` itself.
    """
    def relative_path(filename, root) do
      Paths.relative_to(filename, root) || filename
    end

    @doc "The Credo priority name of an ast-grep severity."
    def severity_priority(severity), do: Map.get(@severity_priorities, severity, :normal)

    @doc """
    The category set in the rule's `metadata.credo_category`, or `nil`.
    Raises `AstGrep.Error` when it is not a valid Credo category.
    """
    def metadata_category!(%Rule{} = rule) do
      metadata_value!(rule, "credo_category", @categories)
    end

    @doc """
    The priority set in the rule's `metadata.credo_priority`, or `nil`.
    Raises `AstGrep.Error` when it is not a valid Credo priority name.
    """
    def metadata_priority!(%Rule{} = rule) do
      metadata_value!(rule, "credo_priority", @priorities)
    end

    @doc "Validates a category given in check params or options."
    def validate_category!(category, context) do
      case to_known_atom(category, @categories) do
        nil ->
          raise ArgumentError,
                "#{context}: invalid category #{inspect(category)}, " <>
                  "expected one of #{inspect(@categories)}"

        category ->
          category
      end
    end

    defp metadata_value!(%Rule{metadata: metadata} = rule, key, allowed) when is_map(metadata) do
      case Map.get(metadata, key) do
        nil ->
          nil

        value ->
          to_known_atom(value, allowed) ||
            raise Error.new(
                    "rule `#{rule.id}`: invalid metadata.#{key} #{inspect(value)}, " <>
                      "expected one of: #{Enum.join(allowed, ", ")}"
                  )
      end
    end

    defp metadata_value!(_rule, _key, _allowed), do: nil

    defp to_known_atom(value, allowed) when is_atom(value),
      do: if(value in allowed, do: value)

    defp to_known_atom(value, allowed) when is_binary(value),
      do: Enum.find(allowed, &(Atom.to_string(&1) == value))

    defp to_known_atom(_value, _allowed), do: nil

    defp to_issue(%Match{} = match, issue_meta, prepared, check) do
      %{category: category, priority: priority} = Map.fetch!(prepared.issue_opts, match.rule_id)
      params = IssueMeta.params(issue_meta)

      # The exit status follows the issue's category (which may come from the
      # rule's metadata), unless set explicitly in the check's params.
      exit_status =
        params[:__exit_status__] || params[:exit_status] || Credo.Check.to_exit_status(category)

      check.format_issue(issue_meta,
        message: message(match, prepared.prefix_rule_id?),
        trigger: trigger(match.text),
        line_no: match.range.start.line,
        column: match.range.start.column,
        category: category,
        priority: priority,
        exit_status: exit_status
      )
    end

    defp message(%Match{rule_id: id, message: message}, prefix?) do
      message = if message in [nil, ""], do: nil, else: message

      case {prefix?, message} do
        {true, nil} -> "[#{id}]"
        {true, message} -> "[#{id}] #{message}"
        {false, nil} -> id
        {false, message} -> message
      end
    end

    # The first line of the matched text: Credo expects the trigger to be found
    # on the issue's line, at its column.
    defp trigger(text) do
      case text |> String.split("\n", parts: 2) |> hd() |> String.trim_trailing("\r") do
        "" -> Issue.no_trigger()
        line -> line
      end
    end
  end
end
