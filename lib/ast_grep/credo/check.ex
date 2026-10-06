if Code.ensure_loaded?(Credo.Check) do
  defmodule AstGrep.Credo.Check do
    use Credo.Check,
      category: :warning,
      base_priority: :normal,
      param_defaults: [
        config: :auto,
        paths: [],
        utils: [],
        only: nil,
        except: [],
        category: :warning
      ],
      explanations: [
        check: """
        Reports the matches of ast-grep rules (https://ast-grep.github.io) as
        Credo issues.

        The rules come from the project's `sgconfig.yml` (its `ruleDirs` and
        `utilDirs`) and/or from explicitly configured rule files. Each issue is
        prefixed with the id of the rule that matched, e.g.
        `[no-io-inspect] Remove IO.inspect(user)`. See the rule's `message`,
        `note` and `url` for an explanation of the issue.
        """,
        params: [
          config: """
          Path to an ast-grep project config (`sgconfig.yml`). `:auto` searches
          the current directory and its parents for `sgconfig.yml` /
          `sgconfig.yaml`; `false` disables loading a config.
          """,
          paths: "Extra rule files or directories to load (relative to the current directory).",
          utils: "Extra utility rule files or directories (relative to the current directory).",
          only: "Only run the rules with these ids (`nil` runs all rules).",
          except: "Do not run the rules with these ids.",
          category: """
          The category of the issues. A rule can override it with
          `metadata: {credo_category: readability}`.
          """
        ]
      ]

    @moduledoc """
    A Credo check running [ast-grep](https://ast-grep.github.io) rules.

    Add it to the `checks` of your `.credo.exs`:

        %{
          configs: [
            %{
              name: "default",
              checks: %{
                extra: [
                  # runs the rules of the nearest sgconfig.yml
                  {AstGrep.Credo.Check, []}
                ]
              }
            }
          ]
        }

    With params:

        {AstGrep.Credo.Check,
         [
           config: "tools/sgconfig.yml",
           paths: ["priv/ast_grep/rules", "priv/ast_grep/extra.yml"],
           utils: ["priv/ast_grep/utils"],
           except: ["prefer-enum-empty"],
           category: :readability
         ]}

    Credo runs a check module at most once, with a single set of params. To
    enable, disable or configure rules individually in `.credo.exs`, define
    one Credo check per rule with `AstGrep.Credo.Rule` (and exclude those
    rules here with `:except`, or keep them out of the config's `ruleDirs`).

    ## Params

      * `:config` - path to an ast-grep project config (`sgconfig.yml`),
        whose `ruleDirs` and `utilDirs` are loaded. Defaults to `:auto`,
        which looks for `sgconfig.yml`/`sgconfig.yaml` in the current
        directory and then its parents. `false` disables config loading.
      * `:paths` - extra rule files/directories, relative to the current
        directory. Default: `[]`.
      * `:utils` - extra utility rule files/directories. Default: `[]`.
      * `:only` / `:except` - rule ids to keep / drop. Default: `nil` / `[]`.
      * `:category` - the category of the issues. Default: `:warning`.

    When no config is found and no `:paths` are given, the check reports
    nothing. When the rules cannot be loaded (invalid YAML, unknown
    language, missing file, ...), the check prints the reason and raises an
    `AstGrep.Error`, which makes `mix credo` fail loudly.

    ## Issues

    Each match becomes an issue with the message `"[rule-id] message"`
    at the start of the matched node. Rule `files`/`ignores` globs are
    matched against the file path relative to the config's directory (or the
    current directory without a config). `ast-grep-ignore` comments as well
    as Credo's `# credo:disable-for-...` comments suppress issues.

    The priority of an issue is derived from the rule's severity:

    | severity  | priority  |
    | --------- | --------- |
    | `error`   | `:higher` |
    | `warning` | `:high`   |
    | `info`    | `:normal` |
    | `hint`    | `:low` (only shown with `mix credo --strict`) |

    Rules can override the issue category and priority with metadata:

        id: no-io-inspect
        language: elixir
        severity: warning
        message: Remove IO.inspect($A)
        metadata:
          credo_category: readability  # consistency/design/readability/refactor/warning
          credo_priority: low          # higher/high/normal/low/ignore
        rule:
          pattern: IO.inspect($A)

    A `priority:` param set on the check in `.credo.exs` applies to the
    issues of rules without a `credo_priority`.

    The rules are loaded and compiled once per Credo run, not once per file.
    """

    alias AstGrep.{Config, Error, RuleSet}
    alias AstGrep.Credo.Runner

    @impl true
    def run_on_all_source_files(exec, source_files, params) do
      case prepare!(params) do
        nil -> :ok
        prepared -> super(exec, source_files, Keyword.put(params, Runner.params_key(), prepared))
      end
    end

    @impl true
    def run(%SourceFile{} = source_file, params) do
      case Keyword.get_lazy(params, Runner.params_key(), fn -> prepare!(params) end) do
        nil -> []
        prepared -> Runner.issues(source_file, prepared, params, __MODULE__)
      end
    end

    # Loads the rules, returns `nil` when there are none.
    defp prepare!(params) do
      case load_rule_set(params) do
        {:ok, nil} ->
          nil

        {:ok, rule_set} ->
          rule_set =
            RuleSet.filter(rule_set, only: param(params, :only), except: param(params, :except))

          if RuleSet.rules(rule_set) == [] do
            nil
          else
            Runner.prepare(rule_set,
              category:
                Runner.validate_category!(
                  Params.category(params, __MODULE__),
                  inspect(__MODULE__)
                ),
              priority: params[:__priority__] || params[:priority],
              metadata?: true,
              prefix_rule_id?: true
            )
          end

        {:error, %Error{} = error} ->
          message = "#{inspect(__MODULE__)} could not load ast-grep rules: #{error.message}"
          UI.warn([:red, "** (ast_grep) ", message])
          raise Error.new(message, error.path)
      end
    end

    defp load_rule_set(params) do
      cwd = File.cwd!()
      paths = params |> param(:paths) |> expand_all(cwd)
      utils = params |> param(:utils) |> expand_all(cwd)

      case config_path(param(params, :config), cwd) do
        nil when paths == [] ->
          {:ok, nil}

        nil ->
          RuleSet.load(paths, utils: utils, root: cwd)

        config_path ->
          with {:ok, %Config{} = config} <- Config.load(config_path) do
            RuleSet.load(config.rule_dirs ++ paths,
              utils: config.util_dirs ++ utils,
              root: config.root
            )
          end
      end
    end

    defp config_path(config, cwd) when config in [nil, :auto] do
      case Config.find(cwd) do
        {:ok, path} -> path
        :error -> nil
      end
    end

    defp config_path(false, _cwd), do: nil
    defp config_path(path, cwd) when is_binary(path), do: Path.expand(path, cwd)

    defp config_path(other, _cwd) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}: invalid :config param #{inspect(other)}, " <>
              "expected a path, :auto or false"
    end

    defp param(params, name), do: Params.get(params, name, __MODULE__)

    defp expand_all(paths, cwd), do: paths |> List.wrap() |> Enum.map(&Path.expand(&1, cwd))
  end
end
