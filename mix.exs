defmodule Fate.MixProject do
  use Mix.Project

  def project do
    [
      app: :fate,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      description: "High-performance probabilistic data structures for Elixir",
      package: [
        maintainers: ["Gustavo Gawryszewski"],
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/gawryco/fate",
          "Hex" => "https://hex.pm/packages/fate"
        },
        files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
      ],
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:benchee, "~> 1.2", only: :dev},
      {:cuckoo_filter, "~> 1.0", only: :dev},
      {:talan, "~> 0.2", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:hll, "~> 0.1", only: :dev, optional: true},
      {:hypex, "~> 1.1", only: :dev, optional: true},
      {:xxh3, "~> 0.3", optional: true},
      {:xxhash, "~> 0.3", optional: true},
      {:murmur, "~> 2.0", optional: true}
    ]
  end
end
