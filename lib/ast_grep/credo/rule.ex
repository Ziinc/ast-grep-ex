if Code.ensure_loaded?(Credo.Check) do
  defmodule AstGrep.Credo.Rule do
    @moduledoc """
    Defines a Credo check from a single [ast-grep](https://ast-grep.github.io)
    rule.

    Each module defined this way is a regular Credo check: it can be enabled,
    disabled and configured on its own in `.credo.exs`, and `mix credo explain`
    shows the rule's message, note and url.

        defmodule MyApp.Checks.NoIoInspect do
          use AstGrep.Credo.Rule, file: "priv/ast_grep/rules/no_io_inspect.yml"
        end

        defmodule MyApp.Checks.NoDbg do
          use AstGrep.Credo.Rule,
            rule: \"\"\"
            id: no-dbg
            language: elixir
            severity: error
            message: Remove dbg calls
            rule:
              pattern: dbg($$$)
            \"\"\"
        end

        defmodule MyApp.Checks.NoApply do
          use AstGrep.Credo.Rule,
            category: :refactor,
            rule: %{
              id: "no-apply",
              language: "elixir",
              message: "Avoid apply/3",
              rule: %{pattern: "apply($M, $F, $A)"}
            }
        end

    Then in `.credo.exs` (the modules must be compiled, e.g. defined in
    `lib/` or loaded with the config's `requires:`):

        %{
          configs: [
            %{
              name: "default",
              checks: %{
                extra: [
                  {MyApp.Checks.NoIoInspect, []},
                  {MyApp.Checks.NoDbg, [priority: :high]},
                  {MyApp.Checks.NoApply, false}
                ]
              }
            }
          ]
        }

    ## Options

      * `:file` - path to a YAML file holding the rule, relative to the
        project root (the current directory at compile time). The module is
        recompiled when the file changes.
      * `:rule` - the rule, inline: a YAML string, or a map / keyword list
        using ast-grep's keys (see `AstGrep.RuleSet.compile/2`).
      * `:utils` - utility rule files or directories (for `matches:`).
      * `:config` - path to an `sgconfig.yml` whose `utilDirs` are loaded. Its
        directory is also the root that the rule's `files`/`ignores` globs
        are relative to (the project root otherwise).
      * `:category` - the check's category. Defaults to the rule's
        `metadata.credo_category`, else `:warning`.
      * `:base_priority` - the check's priority. Defaults to the rule's
        `metadata.credo_priority`, else is derived from its severity
        (`error` → `:higher`, `warning` → `:high`, `info` → `:normal`,
        `hint` → `:low`).
      * `:id` - the Credo check id (defaults to the module name).

    Exactly one of `:file` and `:rule` must be given, and it must define
    exactly one rule (rules with `severity: off` are dropped), otherwise
    compilation fails.

    The rule is validated and compiled when the module is compiled. At
    runtime it is compiled once and cached in `:persistent_term`.

    ## Issues

    Each match is reported at the start of the matched node with the rule's
    interpolated message. The usual Credo params (`priority:`, `category:`,
    `exit_status:`, `files:`) can be set in `.credo.exs`. `ast-grep-ignore`
    comments and Credo's `# credo:disable-for-...` comments suppress issues.

    The module also defines `rule/0`, returning the `AstGrep.Rule` it checks.
    """

    alias AstGrep.{Config, Error, Paths, RuleSet}
    alias AstGrep.Credo.Runner

    @options [:file, :rule, :utils, :config, :category, :base_priority, :id]

    @doc false
    defmacro __using__(opts) do
      unless Keyword.keyword?(opts) do
        raise ArgumentError,
              "use AstGrep.Credo.Rule expects a keyword list, got: #{Macro.to_string(opts)}"
      end

      case Keyword.keys(opts) -- @options do
        [] ->
          :ok

        unknown ->
          raise ArgumentError,
                "unknown options for AstGrep.Credo.Rule: #{inspect(unknown)}, " <>
                  "expected: #{inspect(@options)}"
      end

      check_opts =
        [
          category: quote(do: @__ast_grep_definition__.category),
          base_priority: quote(do: @__ast_grep_definition__.base_priority),
          docs_uri: quote(do: @__ast_grep_definition__.docs_uri),
          explanations: quote(do: [check: @__ast_grep_definition__.explanation])
        ] ++ Keyword.take(opts, [:id])

      quote do
        @__ast_grep_definition__ AstGrep.Credo.Rule.__definition__!(__ENV__, unquote(opts))

        for resource <- @__ast_grep_definition__.external_resources do
          @external_resource resource
        end

        use Credo.Check, unquote(check_opts)

        @doc "Returns the ast-grep rule checked by this module."
        @spec rule() :: AstGrep.Rule.t()
        def rule, do: @__ast_grep_definition__.rule

        @doc false
        def __ast_grep_source__ do
          Map.take(@__ast_grep_definition__, [:sources, :utils, :hash, :root])
        end

        @impl true
        def run_on_all_source_files(exec, source_files, params) do
          prepared = AstGrep.Credo.Rule.__prepare__(__MODULE__, params)

          super(
            exec,
            source_files,
            Keyword.put(params, AstGrep.Credo.Runner.params_key(), prepared)
          )
        end

        @impl true
        def run(%Credo.SourceFile{} = source_file, params) do
          prepared =
            Keyword.get_lazy(params, AstGrep.Credo.Runner.params_key(), fn ->
              AstGrep.Credo.Rule.__prepare__(__MODULE__, params)
            end)

          AstGrep.Credo.Runner.issues(source_file, prepared, params, __MODULE__)
        end
      end
    end

    @doc false
    # Prepares the rule set of `module` for a run with `params`.
    def __prepare__(module, params) do
      %{root: root} = source = module.__ast_grep_source__()

      Runner.prepare(rule_set(module, source),
        category: Credo.Check.Params.category(params, module),
        priority: Credo.Check.Params.priority(params, module),
        metadata?: false,
        prefix_rule_id?: false,
        root: root && Path.expand(root)
      )
    end

    # The compiled rule set of `module`, cached in `:persistent_term` (keyed
    # by a hash of the rule sources, so recompiled modules get a fresh one).
    defp rule_set(module, %{sources: sources, utils: utils, hash: hash}) do
      key = {__MODULE__, module, hash}

      case :persistent_term.get(key, nil) do
        nil ->
          rule_set = RuleSet.compile!(sources, utils: utils)
          :persistent_term.put(key, rule_set)
          rule_set

        rule_set ->
          rule_set
      end
    end

    @doc false
    # Loads and validates the rule at compile time. Returns plain data only
    # (it is stored in a module attribute and read from function bodies).
    def __definition__!(%Macro.Env{} = env, opts) do
      cwd = File.cwd!()
      config = load_config!(env, opts[:config], cwd)
      util_paths = config_utils(config) ++ expand_all(opts[:utils], cwd)
      {rule_paths, inline, origin} = rule_source!(env, opts, cwd)

      rule_set =
        case RuleSet.load(rule_paths, utils: util_paths, rules: inline, root: cwd) do
          {:ok, rule_set} -> rule_set
          {:error, %Error{message: message}} -> compile_error!(env, message)
        end

      rule = single_rule!(env, rule_set, origin)

      {category, base_priority} =
        try do
          category =
            (opts[:category] &&
               Runner.validate_category!(opts[:category], "AstGrep.Credo.Rule")) ||
              Runner.metadata_category!(rule) || :warning

          base_priority =
            opts[:base_priority] || Runner.metadata_priority!(rule) ||
              Runner.severity_priority(rule.severity)

          {category, base_priority}
        rescue
          error in [Error, ArgumentError] -> compile_error!(env, Exception.message(error))
        end

      %{
        rule: rule,
        category: category,
        base_priority: base_priority,
        explanation: explanation(rule, origin),
        docs_uri: rule.url || "https://ast-grep.github.io/reference/yaml.html",
        sources: rule_set.sources,
        utils: rule_set.utils,
        hash: :erlang.phash2({rule_set.sources, rule_set.utils}),
        root: config && Path.relative_to(config.root, cwd),
        external_resources:
          Enum.map(
            config_resources(config) ++ rule_paths ++ util_files(util_paths),
            &Path.relative_to(&1, cwd)
          )
      }
    end

    defp rule_source!(env, opts, cwd) do
      case {Keyword.get(opts, :file), Keyword.get(opts, :rule)} do
        {nil, nil} ->
          compile_error!(env, "use AstGrep.Credo.Rule requires a :file or a :rule option")

        {file, nil} when is_binary(file) ->
          {[Path.expand(file, cwd)], [], "file `#{file}`"}

        {nil, rule} when is_binary(rule) or is_map(rule) or is_list(rule) ->
          {[], [rule], "inline rule"}

        {nil, rule} ->
          compile_error!(
            env,
            "invalid :rule option, expected YAML, a map or a keyword list, got: #{inspect(rule)}"
          )

        {file, nil} ->
          compile_error!(env, "invalid :file option, expected a path, got: #{inspect(file)}")

        {_file, _rule} ->
          compile_error!(env, "use AstGrep.Credo.Rule accepts either :file or :rule, not both")
      end
    end

    defp single_rule!(env, rule_set, origin) do
      case RuleSet.rules(rule_set) do
        [rule] ->
          rule

        [] ->
          compile_error!(
            env,
            "#{origin} must define exactly one rule, found none " <>
              "(rules with `severity: off` are ignored)"
          )

        rules ->
          ids = Enum.map_join(rules, ", ", & &1.id)

          compile_error!(
            env,
            "#{origin} must define exactly one rule, found #{length(rules)}: #{ids}. " <>
              "Define one module per rule, or use AstGrep.Credo.Check for a set of rules"
          )
      end
    end

    defp load_config!(_env, nil, _cwd), do: nil

    defp load_config!(env, path, cwd) when is_binary(path) do
      case Config.load(Path.expand(path, cwd)) do
        {:ok, config} -> config
        {:error, %Error{message: message}} -> compile_error!(env, message)
      end
    end

    defp load_config!(env, other, _cwd),
      do: compile_error!(env, "invalid :config option, expected a path, got: #{inspect(other)}")

    defp config_utils(nil), do: []
    defp config_utils(%Config{util_dirs: dirs}), do: dirs

    defp config_resources(nil), do: []
    defp config_resources(%Config{path: path}), do: [path]

    defp util_files(paths) do
      Enum.flat_map(paths, fn path ->
        if File.dir?(path),
          do: Paths.walk(path, &(Path.extname(&1) in [".yml", ".yaml"])),
          else: [path]
      end)
    end

    defp expand_all(paths, cwd), do: paths |> List.wrap() |> Enum.map(&Path.expand(&1, cwd))

    defp explanation(rule, origin) do
      details =
        Enum.join(
          [
            "language: #{rule.language}",
            "severity: #{rule.severity}",
            if(rule.fixable, do: "fixable with `mix ast_grep.scan --fix`")
          ]
          |> Enum.reject(&is_nil/1),
          ", "
        )

      [
        rule.message,
        rule.note,
        rule.url && "See: #{rule.url}",
        "This check runs the ast-grep rule `#{rule.id}` (#{details}), defined in #{origin}."
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map_join("\n\n", &String.trim/1)
    end

    defp compile_error!(env, message) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "AstGrep.Credo.Rule: #{message}"
    end
  end
end
