# DemoApp: an `ast_grep` example project

A small Elixir app (`DemoApp.Accounts`, `DemoApp.Orders`, ...) that uses
every feature of the [`ast_grep`](../../README.md) library. Its code breaks
the project's lint rules **on purpose**, so `mix credo` and
`mix ast_grep.scan` have something to report.

It shows how to:

- write ast-grep rules in `rules/` (compatible with the `sg` CLI) and run
  them with `mix ast_grep.scan` and with Credo,
- wrap single rules as their own Credo checks,
- use the Elixir API (`scripts/api_tour.exs`),
- test your rules (`test/rules_test.exs`, `test/credo_checks_test.exs`) and
  your lint setup end to end (`test/e2e_test.exs`).

## Layout

```
.
├── sgconfig.yml                  # ruleDirs: [rules], utilDirs: [utils]
├── rules/                        # one ast-grep rule per file (see table below)
├── utils/dbg_call.yml            # global utility rule, used with `matches: dbg-call`
├── priv/ast_grep/checks/
│   └── no_string_to_atom.yml     # rule run by its own Credo check (outside ruleDirs)
├── credo_checks/                 # per-rule Credo checks (`use AstGrep.Credo.Rule`)
│   ├── no_string_to_atom.ex      #   rule from a YAML file
│   └── no_process_sleep.ex       #   inline rule (map)
├── .credo.exs                    # AstGrep.Credo.Check + the per-rule checks
├── lib/                          # the app, with intentional rule violations
├── assets/js/app.js              # JavaScript, checked by a JavaScript rule
├── scripts/api_tour.exs          # guided tour of the AstGrep API
├── config/config.exs             # builds the NIF from source
└── test/
    ├── rules_test.exs            # unit tests for each rule in rules/
    ├── credo_checks_test.exs     # Credo.Test.Case tests for credo_checks/
    ├── e2e_test.exs              # runs the mix commands below, asserts exact output
    └── golden/                   # expected files after `mix ast_grep.scan --fix`
```

## The rules

| Rule (`rules/`)              | Severity | Credo category / priority | Demonstrates |
| ---------------------------- | -------- | ------------------------- | ------------ |
| `no-io-inspect`              | warning  | warning / high            | `pattern`, `$A` metavariable in `message` and `fix`, `note`, `url`, `ignores: [test/**, scripts/**]` |
| `no-dbg`                     | error    | warning / higher          | `matches:` a global util from `utils/` (`dbg($$$)`); error makes `mix ast_grep.scan` exit non-zero |
| `prefer-direct-call`         | info     | refactor / normal         | `$$$ARGS`, `constraints` (`kind: atom`), `transform` (`substring`) in message and fix |
| `bang-for-raising-functions` | warning  | design / high             | relational `has` with `stopBy: end`, `constraints` with `regex` |
| `snake-case-atoms`           | info     | consistency / normal      | `kind` + `regex`, `transform` (`convert` / `toCase: snakeCase`) in message and fix |
| `nested-case`                | hint     | refactor / **normal**     | `inside` with `stopBy: end`, `not`, `kind`; `metadata.credo_priority` overrides the hint's `low` |
| `prefer-enum-empty`          | hint     | readability / low         | hint severity: only shown by `mix credo --strict` |
| `no-io-puts-in-lib`          | info     | warning / normal          | `files: [lib/**/*.ex]` + `ignores: [lib/demo_app/cli.ex]` |
| `no-logger-debug`            | off      | -                         | `severity: off`: kept in the repo, never run |
| `no-console-log`             | warning  | -                         | a JavaScript rule: run by `mix ast_grep.scan`/`sg scan`, never by Credo (it only reads Elixir) |

Every file in `rules/` has a header comment explaining what it shows.

Per-rule Credo checks (`credo_checks/`):

| Check                           | Rule                                          | Demonstrates |
| ------------------------------- | --------------------------------------------- | ------------ |
| `DemoApp.Checks.NoStringToAtom` | `priv/ast_grep/checks/no_string_to_atom.yml` | `use AstGrep.Credo.Rule, file: ...`; category from `metadata.credo_category`, priority from `severity: error`; own `mix credo explain` text |
| `DemoApp.Checks.NoProcessSleep` | inline `rule: %{...}` map                     | `:category` / `:base_priority` options |

The per-rule YAML lives outside `ruleDirs`, otherwise `AstGrep.Credo.Check`
would report it a second time. The check modules live in `credo_checks/`,
not `lib/`: Credo is a dev/test-only dependency, so they can't be part of the
app. `.credo.exs` loads them with `requires:`, and `test/test_helper.exs`
loads them for the tests.

`.credo.exs` also disables the Credo checks the ast-grep rules replace
(`Warning.IoInspect`, `Warning.Dbg`, `Warning.UnsafeToAtom`,
`Refactor.Apply`, `Warning.ExpensiveEmptyEnumCheck`), so nothing is
reported twice.

### Suppression comments

In `lib/demo_app/accounts.ex`, `lib/demo_app/orders.ex` and `assets/js/app.js`:

```elixir
# ast-grep-ignore                       <- every rule, next line
IO.inspect(order)

# ast-grep-ignore: snake-case-atoms     <- only this rule
provider_id: Map.get(params, :customerId),

# credo:disable-for-next-line DemoApp.Checks.NoStringToAtom   <- Credo only
String.to_atom(user.role) == :admin
```

## Running it

Requirements: Elixir 1.15+, and Rust plus a C compiler. No precompiled NIF
has been published yet, so `config/config.exs` builds it from source:

```elixir
config :rustler_precompiled, force_build_all: true
```

> `config :rustler_precompiled, :force_build, ast_grep: true` would be the
> usual per-library switch, but ast_grep 0.1.0 passes its own `force_build:`
> option to RustlerPrecompiled, which takes precedence over it.
> `AST_GREP_BUILD=1 mix compile` works too.

```console
$ cd examples/demo_app
$ mix deps.get
$ mix compile
```

### `mix credo --strict`

Exits with status 31 (the OR of every category's exit bit) because of the
intentional issues:

```
$ mix credo --strict
Checking 13 source files ...

  Software Design
┃
┃ [D] ↑ String.to_atom/1 can exhaust the atom table: use
┃       String.to_existing_atom/1
┃       lib/demo_app/accounts.ex:23:23 #(DemoApp.Accounts.role)
┃ [W] ↗ [bang-for-raising-functions] fetch_user/1 can raise: name it fetch_user!
┃       or return an error tuple
┃       lib/demo_app/accounts.ex:15:3 #(DemoApp.Accounts.fetch_user)

  Code Readability
┃
┃ [W] ↘ [prefer-enum-empty] Use Enum.empty?(orders) instead of length(orders) ==
┃       0
┃       lib/demo_app/orders.ex:24:8 #(DemoApp.Orders.ship_all)

  Refactoring opportunities
┃
┃ [W] → [prefer-direct-call] Call DemoApp.Mailer.deliver(...) directly instead
┃       of using apply/3
┃       lib/demo_app/orders.ex:44:5 #(DemoApp.Orders.deliver)
┃ [F] → Avoid Process.sleep(100): it blocks the caller
┃       lib/demo_app/orders.ex:43:5 #(DemoApp.Orders.deliver)
┃ [W] → [nested-case] Nested case on order.status: consider `with` or a helper
┃       function
┃       lib/demo_app/orders.ex:12:9 #(DemoApp.Orders.ship)

  Warnings - please take a look
┃
┃ [W] ↑ [no-dbg] Remove dbg/1 before committing
┃       lib/demo_app/accounts.ex:34:5 #(DemoApp.Accounts.without_email)
┃ [W] ↗ [no-io-inspect] Remove debugging call IO.inspect(build_user(params))
┃       lib/demo_app/accounts.ex:10:12 #(DemoApp.Accounts.register)
┃ [W] → [no-io-puts-in-lib] Use Logger instead of IO.puts in library code
┃       lib/demo_app/orders.ex:41:5 #(DemoApp.Orders.deliver)

  Consistency
┃
┃ [W] → [snake-case-atoms] Use :first_name instead of :firstName
┃       lib/demo_app/accounts.ex:40:29 #(DemoApp.Accounts.build_user)
...
39 mods/funs, found 1 consistency issue, 3 warnings, 3 refactoring opportunities, 1 code readability issue, 2 software design suggestions.
```

Without `--strict`, the `prefer-enum-empty` hint (priority low) is hidden,
while `nested-case`, also a hint, is still shown thanks to its
`credo_priority: normal`. Try `mix credo explain lib/demo_app/accounts.ex:23:23`
to see the per-rule check's explanation (message, note and url of the rule).

### `mix ast_grep.scan`

Runs the rules of `sgconfig.yml` on every file of a language they target,
including `assets/js/app.js`. Exits non-zero because `no-dbg` has severity
`error`:

```
$ mix ast_grep.scan
assets/js/app.js:4:3: warning[no-console-log] Remove console.log("booting app for", user.name)
lib/demo_app/accounts.ex:10:12: warning[no-io-inspect] Remove debugging call IO.inspect(build_user(params))
    IO.inspect/1 calls are usually debugging leftovers. Use Logger, or
    `mix ast_grep.scan --fix` to remove them.
lib/demo_app/accounts.ex:15:3: warning[bang-for-raising-functions] fetch_user/1 can raise: name it fetch_user! or return an error tuple
    By convention, functions that raise end with `!` (`fetch_user!/1`).
lib/demo_app/accounts.ex:34:5: error[no-dbg] Remove dbg/1 before committing
lib/demo_app/accounts.ex:40:29: info[snake-case-atoms] Use :first_name instead of :firstName
lib/demo_app/orders.ex:12:9: hint[nested-case] Nested case on order.status: consider `with` or a helper function
lib/demo_app/orders.ex:24:8: hint[prefer-enum-empty] Use Enum.empty?(orders) instead of length(orders) == 0
    length/1 walks the whole list, Enum.empty?/1 doesn't.
lib/demo_app/orders.ex:41:5: info[no-io-puts-in-lib] Use Logger instead of IO.puts in library code
lib/demo_app/orders.ex:44:5: info[prefer-direct-call] Call DemoApp.Mailer.deliver(...) directly instead of using apply/3
Found 9 matches (1 error, 3 warnings, 3 infos, 2 hints) in 15 files.
** (Mix) ast-grep found 1 error
```

Note that `no-string-to-atom` and `no-process-sleep` are not reported here:
they are not in `ruleDirs`, they only run as Credo checks.

`mix lint` (an alias for `credo --strict` then `ast_grep.scan`) stops at the
first failing step, so with this demo's intentional issues it only shows
Credo's report.

### `mix ast_grep.scan --fix`

> **This rewrites files in place.** Run it on a clean git tree, and undo it
> with `git checkout -- lib` (or `git stash`) to get the demo's issues back.

```
$ mix ast_grep.scan --fix
Applied 4 fixes to 2 files.
assets/js/app.js:4:3: warning[no-console-log] Remove console.log("booting app for", user.name)
lib/demo_app/accounts.ex:15:3: warning[bang-for-raising-functions] fetch_user/1 can raise: name it fetch_user! or return an error tuple
    By convention, functions that raise end with `!` (`fetch_user!/1`).
lib/demo_app/accounts.ex:34:5: error[no-dbg] Remove dbg/1 before committing
lib/demo_app/orders.ex:12:9: hint[nested-case] Nested case on order.status: consider `with` or a helper function
lib/demo_app/orders.ex:41:5: info[no-io-puts-in-lib] Use Logger instead of IO.puts in library code
Found 5 matches (1 error, 2 warnings, 1 info, 1 hint) in 7 files.
** (Mix) ast-grep found 1 error
```

```diff
-    user = IO.inspect(build_user(params))
+    user = build_user(params)
-      name: Map.get(params, :firstName),
+      name: Map.get(params, :first_name),
-    if length(orders) == 0 do
+    if Enum.empty?(orders) do
-    apply(DemoApp.Mailer, :deliver, [order.email, :shipped])
+    DemoApp.Mailer.deliver(order.email, :shipped)
```

The expected results are in `test/golden/`.

### `mix run scripts/api_tour.exs`

A guided tour of the API: `AstGrep.find/3` with a pattern and with a rule
map, `replace/4`, `RuleSet.from_config!/1` and `scan_file/3`,
`apply_fixes/2` (in memory, nothing is written), `RuleSet.filter/2`,
`scan/3` with a `:path`, `RuleSet.compile!/1`, `dump_tree/2` and
`languages/0`. An excerpt:

```
== AstGrep.find/3 with a pattern: "IO.inspect($VALUE, $$$OPTS)"

line 3: IO.inspect(cart, label: "cart")
  $VALUE = "cart"
  $$$OPTS = ["label: \"cart\""]

== AstGrep.replace/4: Enum.sum(Enum.map(...)) -> Enum.sum_by(...)

-     total = Enum.sum(Enum.map(cart.items, & &1.price))
+     total = Enum.sum_by(cart.items, & &1.price)

== AstGrep.RuleSet.from_config!/1: the rules of sgconfig.yml

warning bang-for-raising-functions  elixir
hint    nested-case                 elixir
warning no-console-log              javascript
error   no-dbg                      elixir
warning no-io-inspect               elixir (fixable)
...

== AstGrep.apply_fixes/2 (in memory, the file is not written)

-     user = IO.inspect(build_user(params))
+     user = build_user(params)
-       name: Map.get(params, :firstName),
+       name: Map.get(params, :first_name),

== AstGrep.scan/3: the :path option selects files/ignores globs

lib/demo_app/orders.ex => 1 match(es)
lib/demo_app/cli.ex => 0 match(es)
scripts/api_tour.exs => 0 match(es)

== AstGrep.dump_tree/2: "IO.inspect(user)" (to find kinds when writing rules)

    source (1,1)-(1,17)
      call (1,1)-(1,17)
        target: dot (1,1)-(1,11)
          left: alias (1,1)-(1,3) "IO"
          right: identifier (1,4)-(1,11) "inspect"
        arguments (1,11)-(1,17)
          identifier (1,12)-(1,16) "user"
```

### `mix test`

```
$ mix test
.................................
Finished in 4.6 seconds (4.6s async, 0.00s sync)
33 tests, 0 failures
```

- `test/rules_test.exs`: for each rule, a "bad" snippet with its exact
  matches (id, line, column, message) and fixed output, and a "good" snippet
  with no matches. Copy this pattern to test your own rules.
- `test/credo_checks_test.exs`: the per-rule checks, with `Credo.Test.Case`.
- `test/e2e_test.exs` (tagged `:e2e`): runs `mix credo --strict --format json`
  (and without `--strict`), `mix ast_grep.scan`, `mix ast_grep.scan --fix`
  (on a copy in a temp dir, compared with `test/golden/`) and
  `mix run scripts/api_tour.exs`, and asserts their exact results. Skip it
  with `mix test --exclude e2e`.

### With the ast-grep CLI

`sgconfig.yml`, `rules/` and `utils/` are plain ast-grep files. With the
[ast-grep CLI](https://ast-grep.github.io/guide/quick-start.html) installed
(`npm i -g @ast-grep/cli`, `cargo install ast-grep` or `brew install ast-grep`):

```
$ ast-grep scan --report-style short
lib/demo_app/accounts.ex:34:5: error[no-dbg]: Remove dbg/1 before committing
lib/demo_app/accounts.ex:40:29: note[snake-case-atoms]: Use :first_name instead of :firstName
lib/demo_app/accounts.ex:10:12: warning[no-io-inspect]: Remove debugging call IO.inspect(build_user(params))
lib/demo_app/accounts.ex:15:3: warning[bang-for-raising-functions]: fetch_user/1 can raise: name it fetch_user! or return an error tuple
assets/js/app.js:4:3: warning[no-console-log]: Remove console.log("booting app for", user.name)
lib/demo_app/orders.ex:12:9: help[nested-case]: Nested case on order.status: consider `with` or a helper function
lib/demo_app/orders.ex:41:5: note[no-io-puts-in-lib]: Use Logger instead of IO.puts in library code
lib/demo_app/orders.ex:24:8: help[prefer-enum-empty]: Use Enum.empty?(orders) instead of length(orders) == 0
lib/demo_app/orders.ex:44:5: note[prefer-direct-call]: Call DemoApp.Mailer.deliver(...) directly instead of using apply/3
Error: 1 error(s) found in code.
```

(ast-grep 0.45.3; the CLI is installed as `sg` too, but on Linux `sg` is often
the unrelated shadow-utils command.)
