defmodule DemoApp.Mailer do
  @moduledoc """
  Sends emails (or pretends to).
  """

  require Logger

  @doc "Delivers the email `template` to `to`."
  def deliver(to, template) do
    Logger.info("sending #{template} email to #{to}")
    :ok
  end
end
