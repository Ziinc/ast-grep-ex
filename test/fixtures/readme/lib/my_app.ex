defmodule MyApp do
  def run(user) do
    IO.inspect(user)
    dbg(user)
    String.to_atom(user.name)
    # ast-grep-ignore
    IO.inspect(:ignored)
    # ast-grep-ignore: no-io-inspect
    IO.inspect(:ignored_by_id)
    # ast-grep-ignore: no-dbg
    IO.inspect(:other_rule_ignored)
  end
end
