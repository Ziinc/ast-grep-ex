defmodule Example do
  def run(user) do
    IO.inspect(user)
    dbg(user)
    apply(Example, :other, [user])

    if length(user.items) == 0 do
      :empty
    end

    # ast-grep-ignore
    IO.inspect(:suppressed)
    # ast-grep-ignore: no-dbg
    dbg(:suppressed)
  end

  def other(user), do: user
end
