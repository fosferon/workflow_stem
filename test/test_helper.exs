ExUnit.start(exclude: [:pending])

# Configure test adapters
Application.put_env(:workflow_stem, :capability_runner_adapter, WorkflowStem.TestCapabilityRunner)
Application.put_env(:workflow_stem, :conversation_handler, WorkflowStem.TestConversationHandler)
Application.put_env(:workflow_stem, :persistence_adapter, nil)
Application.put_env(:workflow_stem, :comm_bus_adapter, nil)
Application.put_env(:workflow_stem, :pipeline_timeout, 5_000)
Application.put_env(:workflow_stem, :spec_discovery, {:workflow_stem, "Elixir.WorkflowStem.Specs."})

# Ensure CacheOwner is started for tests
WorkflowStem.CacheOwner.ensure_started()
