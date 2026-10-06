# A guided tour of the AstGrep API. Run it with:
#
#     mix run scripts/api_tour.exs
#
# It only reads files: fixes are printed, never written.

alias AstGrep.RuleSet

defmodule Tour do
  @moduledoc false

  def section(title), do: IO.puts(["\n", IO.ANSI.format([:bright, "== ", title]), "\n"])

  def code(source), do: source |> String.trim_trailing() |> indent() |> IO.puts()

  def indent(text, prefix \\ "    ") do
    text |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))
  end

  # A minimal line diff of `old` and `new`.
  def diff(old, new) do
    String.split(old, "\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.flat_map(fn
      {:eq, _lines} -> []
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
  end

  def location(match), do: "#{match.range.start.line}:#{match.range.start.column}"
end

source = """
defmodule Shop do
  def checkout(cart, user) do
    IO.inspect(cart, label: "cart")
    total = Enum.sum(Enum.map(cart.items, & &1.price))
    Logger.info("checkout", user_id: user.id, total: total)
    {:ok, total}
  end
end
"""

Tour.section("Sample source")
Tour.code(source)

# -- find/3 with a pattern ----------------------------------------------------

Tour.section(~s|AstGrep.find/3 with a pattern: "IO.inspect($VALUE, $$$OPTS)"|)

{:ok, matches} = AstGrep.find(source, "IO.inspect($VALUE, $$$OPTS)", language: :elixir)

for match <- matches do
  IO.puts("line #{match.range.start.line}: #{match.text}")
  # $VALUE captures one node (a string), $$$OPTS zero or more (a list).
  IO.puts("  $VALUE = #{inspect(match.meta_variables["VALUE"])}")
  IO.puts("  $$$OPTS = #{inspect(match.meta_variables["OPTS"])}")
end

# -- find/3 with a rule object ------------------------------------------------

Tour.section("AstGrep.find/3 with a rule map: calls with keyword arguments")

rule = %{
  kind: "call",
  # `has` + `stopBy: end` looks at all descendants, not only children.
  has: %{kind: "keywords", stopBy: "end"},
  # ...but not the def/defmodule calls that contain them.
  not: %{regex: "^def"}
}

{:ok, matches} = AstGrep.find(source, rule, language: :elixir)
for match <- matches, do: IO.puts("line #{match.range.start.line}: #{match.text}")

# -- replace/4 ------------------------------------------------------------------

Tour.section("AstGrep.replace/4: Enum.sum(Enum.map(...)) -> Enum.sum_by(...)")

{:ok, replaced} =
  AstGrep.replace(
    source,
    "Enum.sum(Enum.map($LIST, $FUN))",
    "Enum.sum_by($LIST, $FUN)",
    language: :elixir
  )

IO.puts(Tour.diff(source, replaced))

# -- RuleSet.from_config/2 + scan_file/3 --------------------------------------

Tour.section("AstGrep.RuleSet.from_config!/1: the rules of sgconfig.yml")

rule_set = RuleSet.from_config!("sgconfig.yml")

for rule <- RuleSet.rules(rule_set) do
  fixable = if rule.fixable, do: " (fixable)", else: ""

  IO.puts(
    "#{String.pad_trailing(to_string(rule.severity), 8)}#{String.pad_trailing(rule.id, 28)}#{rule.language}#{fixable}"
  )
end

path = "lib/demo_app/accounts.ex"
Tour.section("AstGrep.scan_file/3: #{path}")

{:ok, matches} = AstGrep.scan_file(path, rule_set)

for match <- matches do
  IO.puts("#{path}:#{Tour.location(match)} #{match.rule_id}: #{match.message}")
end

# -- apply_fixes/2 ----------------------------------------------------------------

Tour.section("AstGrep.apply_fixes/2 (in memory, the file is not written)")

original = File.read!(path)
fixed = AstGrep.apply_fixes(original, matches)
IO.puts(Tour.diff(original, fixed))

# -- RuleSet.filter/2 ------------------------------------------------------------

Tour.section("AstGrep.RuleSet.filter/2")

only = RuleSet.filter(rule_set, only: ["no-io-inspect", "no-dbg"])
IO.puts("only: #{inspect(RuleSet.rule_ids(only))}")

except = RuleSet.filter(rule_set, except: ["no-console-log"])
IO.puts("except no-console-log: #{length(RuleSet.rule_ids(except))} rules")

{:ok, matches} = AstGrep.scan_file(path, only)
IO.puts("#{path} with only these: #{Enum.map_join(matches, ", ", & &1.rule_id)}")

# -- scan/3 with a path ------------------------------------------------------------

Tour.section("AstGrep.scan/3: the :path option selects files/ignores globs")

snippet = ~s|IO.puts("shipped")|
puts_only = RuleSet.filter(rule_set, only: "no-io-puts-in-lib")

for path <- ["lib/demo_app/orders.ex", "lib/demo_app/cli.ex", "scripts/api_tour.exs"] do
  {:ok, matches} = AstGrep.scan(snippet, puts_only, path: path)
  IO.puts("#{path} => #{length(matches)} match(es)")
end

# -- RuleSet.compile/2 ---------------------------------------------------------------

Tour.section("AstGrep.RuleSet.compile!/1: a rule from a keyword list")

inline =
  RuleSet.compile!(
    id: "no-logger-info",
    language: :elixir,
    severity: :hint,
    message: "Logger.info with $$$ARGS",
    rule: [pattern: "Logger.info($$$ARGS)"]
  )

for match <- AstGrep.scan!(source, inline, language: :elixir) do
  IO.puts("#{Tour.location(match)} #{match.severity}[#{match.rule_id}] #{match.message}")
end

# -- dump_tree/2 -----------------------------------------------------------------------

Tour.section(~s|AstGrep.dump_tree/2: "IO.inspect(user)" (to find kinds when writing rules)|)

{:ok, tree} = AstGrep.dump_tree("IO.inspect(user)", :elixir)
IO.puts(Tour.indent(String.trim_trailing(tree)))

# -- languages/0 ------------------------------------------------------------------------

Tour.section("AstGrep.languages/0")

languages = AstGrep.languages()
IO.puts("#{length(languages)} languages: #{Enum.join(languages, ", ")}")
