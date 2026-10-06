// Front-end entry point, checked by rules/no_console_log.yml
// (with `mix ast_grep.scan` or `sg scan`; Credo only reads Elixir files).
export function init(user) {
  console.log("booting app for", user.name);

  // ast-grep-ignore: no-console-log
  console.log("this one is kept on purpose");

  console.error("errors are fine");
}
