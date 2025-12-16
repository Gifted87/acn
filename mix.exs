defmodule Acn.MixProject do
  use Mix.Project

  def project do
    [
      app: :acn,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :eex, :mnesia],
      mod: {ACN.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # JSON Parser: We handle data structures, not strings.
      {:jason, "~> 1.4"},

      # HTTP Client: We need to make API calls to external services.
      {:httpoison, "~> 2.0"},

      # JWT Token Library: We need to sign and verify security tokens.
      {:joken, "~> 2.6"},

      # Graph Data Structure: We need to build dependency graphs in memory.
      {:libgraph, "~> 0.16.0"},

      # YAML Parser: We need to read configuration files.
      {:yaml_elixir, "~> 2.9"},

      # Test Mocking: Only for the test environment.
      {:mimic, "~> 1.7", only: :test},

      # FIX: Pin jose to avoid OTP 25 compilation error
      {:jose, "1.11.10"},

      # Rustler for Firecracker NIFs
      {:rustler, "~> 0.29.1"},

      # AI / Embeddings / Tensors
      {:bumblebee, "~> 0.6.0"},
      {:exla, "~> 0.9.0"},
      {:nx, "~> 0.9.0"},

      # HTTP Client
      {:req, "~> 0.4.0"},

      # UUID
      {:elixir_uuid, "~> 1.2"},

      # Web / Phoenix (Compatible with Elixir 1.14)
      {:phoenix, "~> 1.6.0"},
      {:plug_cowboy, "~> 2.5"},

      # Hardware Interaction (Nerves)
      {:circuits_gpio, "~> 1.0"}
    ]
  end
end
