defmodule RMQ.MixProject do
  use Mix.Project

  def project do
    [
      app: :rmq,
      version: "0.1.0-beta.0",
      elixir: "~> 1.8",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "RMQ",
      description: "RMQ - a set of tools for convenient work with RabbitMQ",
      source_url: "https://github.com/nmbrone/rmq",
      homepage_url: "https://github.com/nmbrone/rmq",
      package: [
        maintainers: ["Sergey Snozyk"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/nmbrone/rmq"}
      ],
      docs: [
        main: "RMQ",
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 1.4"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:jason, "~> 1.2"},
      {:uuid, "~> 1.1"}
    ]
  end
end
