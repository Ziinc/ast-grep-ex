defmodule DemoApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ast_grep, path: "../.."},
      # No precompiled NIF has been released yet, so the NIF is built from
      # source (see config/config.exs). Needs Rust and a C compiler.
      {:rustler, ">= 0.0.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "ast_grep.scan"]
    ]
  end
end
