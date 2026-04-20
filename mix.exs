defmodule WorkflowStem.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fosferon/workflow_stem"

  def project do
    [
      app: :workflow_stem,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Shared workflow runtime — stepwise, FSM, and flow engines with ALF pipelines",
      package: package(),
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:alf, "~> 0.12"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "workflow_stem",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Leonidas"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
