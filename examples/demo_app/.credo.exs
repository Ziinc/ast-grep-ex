# Credo config: Credo's default checks, plus ast-grep rules as Credo checks.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "scripts/", "credo_checks/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      # Compiles the per-rule checks of credo_checks/ before running Credo
      # (they are not part of the app, see mix.exs).
      requires: ["credo_checks/**/*.ex"],
      strict: false,
      checks: %{
        # Added to Credo's default checks.
        extra: [
          # Runs every rule of the nearest sgconfig.yml (rules/ with the
          # utilities of utils/). Each issue is reported as "[rule-id] message",
          # with a priority derived from the rule's severity and the category
          # of its metadata.credo_category (default: warning).
          #
          # Rules can be skipped with `except:`, or selected with `only:`:
          #
          #   {AstGrep.Credo.Check, except: ["nested-case"]}
          #
          # Other params: config: "path/to/sgconfig.yml", paths: [...],
          # utils: [...], category: :readability.
          {AstGrep.Credo.Check, []},

          # One Credo check per rule (credo_checks/), each configurable on
          # its own. Their rules are kept outside of sgconfig.yml's ruleDirs
          # so that AstGrep.Credo.Check does not report them a second time.
          {DemoApp.Checks.NoStringToAtom, []},
          {DemoApp.Checks.NoProcessSleep, []}
        ],
        # Built-in checks covered by the ast-grep rules above (disabled to
        # avoid duplicate issues).
        disabled: [
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []}
        ]
      }
    }
  ]
}
