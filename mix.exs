defmodule McpBroker.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_broker,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {McpBroker.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:hermes_mcp, "~> 0.14.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:plug_cowboy, "~> 2.5"},
      {:joken, "~> 2.6"}
    ]
  end
end
