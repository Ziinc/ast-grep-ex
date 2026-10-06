defmodule AstGrep.Error do
  @moduledoc """
  Error returned (or raised by the bang functions) when rules fail to load or
  compile, a language is unknown, or a source cannot be scanned.

  `:path` is the file the error relates to (a rule file, a config file or a
  scanned file), or `nil` when the error is not tied to a file.
  """

  defexception [:message, :path]

  @type t :: %__MODULE__{message: String.t(), path: Path.t() | nil}

  @doc false
  @spec new(String.t(), Path.t() | nil) :: t()
  def new(message, path \\ nil), do: %__MODULE__{message: message, path: path}

  @doc false
  # Builds an error whose message is prefixed with the (cwd-relative) path.
  @spec for_file(Path.t(), String.t()) :: t()
  def for_file(path, message) do
    %__MODULE__{message: "#{Path.relative_to_cwd(path)}: #{message}", path: path}
  end
end
