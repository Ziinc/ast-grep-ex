# AstGrep

[ast-grep](https://ast-grep.github.io) for Elixir: structural search, lint
rules and rewrites, powered by a precompiled Rust NIF, with
[Credo](https://github.com/rrrene/credo) integration so your `sg` rules run as
Credo checks.

- Write lint rules once in ast-grep's YAML format and run them with the `sg`
  CLI, `mix ast_grep.scan`, or `mix credo`.
- Search and rewrite code with patterns such as `IO.inspect($A)`.
- Supports every ast-grep built-in language (Elixir, JavaScript/TypeScript,
  HTML, CSS, Rust, Python, ...).

## Installation

```elixir
def deps do
  [
    {:ast_grep, "~> 0.1"},
    # optional, for the Credo checks
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
```

Precompiled NIFs are downloaded for common targets. To build from source
instead (requires Rust 1.91+ and a C compiler), set `AST_GREP_BUILD=1` and add
`{:rustler, ">= 0.0.0", optional: true}` to your deps.

## Writing rules

Rules are standard [ast-grep rule files](https://ast-grep.github.io/reference/yaml.html).
A typical layout, compatible with the `sg` CLI:

```yaml
# sgconfig.yml
ruleDirs:
  - rules
utilDirs:
  - utils
```

```yaml
# rules/no_io_inspect.yml
id: no-io-inspect
language: elixir
severity: warning
message: Remove IO.inspect($A)
note: IO.inspect/1 calls should not be committed.
rule:
  pattern: IO.inspect($A)
fix: $A
ignores:
  - "test/**"
metadata:
  credo_category: warning # optional: consistency | design | readability | refactor | warning
```

Matches can be suppressed with an `# ast-grep-ignore` (or
`# ast-grep-ignore: rule-id`) comment on the preceding line.

## Credo integration

### All rules in one check

Add `AstGrep.Credo.Check` to `.credo.exs`. It loads the rules of the nearest
`sgconfig.yml` (and/or explicit paths) once per Credo run and reports each
match as `[rule-id] message`:

```elixir
%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          {AstGrep.Credo.Check, []},
          # or, with options:
          # {AstGrep.Credo.Check,
          #  config: "sgconfig.yml",   # :auto (default) | path | false
          #  paths: ["priv/ast_grep/rules"],
          #  utils: ["priv/ast_grep/utils"],
          #  only: nil,
          #  except: ["some-rule"],
          #  category: :warning}
        ]
      }
    }
  ]
}
```

### One Credo check per rule

To enable, disable or configure a rule on its own, with its own
`mix credo explain` text, wrap it in a check module:

```elixir
defmodule MyApp.Checks.NoIoInspect do
  use AstGrep.Credo.Rule, file: "priv/ast_grep/rules/no_io_inspect.yml"
end
```

`:rule` (inline YAML, map or keyword list), `:utils`, `:config`, `:category`,
`:base_priority` and `:id` are also accepted. The module recompiles when the
YAML file changes. Add it to `.credo.exs` like any other check:
`{MyApp.Checks.NoIoInspect, []}`. Keep per-rule files out of the config's
`ruleDirs` (or list them in `except:`), or they will be reported twice.

### Severity and category

| ast-grep `severity` | Credo priority |
| ------------------- | -------------- |
| `error`             | higher         |
| `warning`           | high           |
| `info`              | normal         |
| `hint` (default)    | low (shown with `--strict`) |

Issues use the `:warning` category by default. A rule can override this with
`metadata.credo_category` and the priority with `metadata.credo_priority`.
Credo's own `# credo:disable-for-next-line` comments work as usual. Each
rule's `files`/`ignores` globs are matched against paths relative to the
`sgconfig.yml` directory.

## Mix task

```console
$ mix ast_grep.scan                    # uses the nearest sgconfig.yml
$ mix ast_grep.scan lib --rule priv/ast_grep/rules
$ mix ast_grep.scan --fix              # apply the rules' `fix` rewrites
```

The task exits with a non-zero status if any match has severity `error`.

## Library API

```elixir
# Ad-hoc search with metavariables
{:ok, [match]} = AstGrep.find(source, "IO.inspect($A, $$$OPTS)", language: :elixir)
match.meta_variables #=> %{"A" => "user", "OPTS" => ["label: :x"]}
match.range.start    #=> %AstGrep.Position{line: 3, column: 5, offset: 42}

# Rule objects as maps / keyword lists
AstGrep.find(source, [kind: "call", has: [pattern: "IO", stopBy: "end"]], language: :elixir)

# Rewrite
{:ok, new_source} = AstGrep.replace(source, "IO.inspect($A)", "dbg($A)", language: :elixir)

# Lint with a rule set
rule_set = AstGrep.RuleSet.from_config!("sgconfig.yml")
{:ok, matches} = AstGrep.scan_file("lib/my_app.ex", rule_set)
fixed = AstGrep.apply_fixes(File.read!("lib/my_app.ex"), matches)

# Inspect the syntax tree while writing rules
{:ok, tree} = AstGrep.dump_tree("IO.inspect(x)", :elixir)
```

See `AstGrep`, `AstGrep.RuleSet`, `AstGrep.Credo.Check` and
`AstGrep.Credo.Rule` for full documentation.

## Development

```console
$ mix deps.get
$ mix test          # builds the NIF from source in dev/test
```

See [RELEASING.md](RELEASING.md) for how precompiled NIFs are published.

## License

MIT
