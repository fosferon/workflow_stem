defmodule WorkflowStem.MixProject do
  use Mix.Project

  @version "0.5.0-dev"
  @source_url "https://github.com/fosferon/workflow_stem"

  def project do
    [
      app: :workflow_stem,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Shared workflow runtime — stepwise, FSM, and flow engines with ALF pipelines",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WorkflowStem.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:alf, "~> 0.12"},
      {:jason, "~> 1.4"},
      {:mobus_stepwise,
       github: "fosferon/mobus_stepwise", ref: "a6d7245d95ce0d2574ad84af7aa58e89e6441601"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "workflow_stem",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Leonidas"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/{path}#L{line}",
      extras: ["README.md"],
      groups_for_modules: [
        Adapters: [
          WorkflowStem.Adapters.CapabilityRunner,
          WorkflowStem.Adapters.CapabilityInvoker,
          WorkflowStem.Adapters.CheckpointStore,
          WorkflowStem.Adapters.ConversationHandler,
          WorkflowStem.Adapters.ControlStore,
          WorkflowStem.Adapters.EventSink,
          WorkflowStem.Adapters.NotificationAdapter,
          WorkflowStem.Adapters.PersistenceAdapter,
          WorkflowStem.Adapters.ProcessController
        ],
        Engines: ~r"^WorkflowStem.Engines",
        Pipelines: ~r"^WorkflowStem.Pipelines",
        Runner: [
          WorkflowStem.Runner,
          WorkflowStem.EventLog
        ]
      ]
    ]
  end
end
