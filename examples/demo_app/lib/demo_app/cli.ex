defmodule DemoApp.CLI do
  @moduledoc """
  Command line entry point. Printing with IO.puts is fine here: this file is
  in the `ignores` of rules/no_io_puts_in_lib.yml.
  """

  @doc "Prints the app's version."
  def main(_args) do
    IO.puts("demo_app #{DemoApp.version()}")
  end
end
