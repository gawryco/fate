defmodule Fate.MixProject do
  use Mix.Project

  def project do
    [
      app: :fate,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:benchee, "~> 1.2", only: :dev},
      {:cuckoo_filter, "~> 1.0", only: :dev},
      {:talan, "~> 0.2", only: :dev},
      {:xxh3, "~> 0.3", optional: true},
      {:xxhash, "~> 0.3", optional: true},
      {:murmur, "~> 2.0", optional: true}
    ]
  end
end
