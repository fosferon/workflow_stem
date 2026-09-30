defmodule WorkflowStem.Test.DefinitionBlocks do
  @moduledoc false
  # Stand-ins for a host's blocks. Each records what it was asked, so a test
  # can assert on the arguments a definition handed it.

  defmodule Runner do
    @moduledoc false
    alias WorkflowStem.Definition.Blocks

    def execute(tenant_id, handle, input) do
      case Blocks.execute(WorkflowStem.Test.DefinitionBlocks.registry(), tenant_id, handle, input) do
        :unregistered -> {:error, {:unknown_capability, handle}}
        result -> result
      end
    end
  end

  defmodule Call do
    @moduledoc false
    @behaviour WorkflowStem.Definition.Block
    def handle, do: "stub.call"
    def describe, do: %{label: "Stub call"}

    def run(arguments, env) do
      send(self(), {:called, env.node, arguments})

      case Process.get({:stub, env.node}) do
        nil -> {:ok, Map.get(arguments, "returns")}
        fun when is_function(fun, 1) -> fun.(arguments)
        fixed -> fixed
      end
    end
  end

  def registry, do: %{"stub.call" => Call}
end
