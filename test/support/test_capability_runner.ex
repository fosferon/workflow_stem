defmodule WorkflowStem.TestCapabilityRunner do
  @moduledoc """
  Test double for WorkflowStem.Adapters.CapabilityRunner.

  Records calls and returns configurable results. Used in engine tests
  to verify capability action execution without real domain logic.
  """

  @behaviour WorkflowStem.Adapters.CapabilityRunner

  @impl true
  def execute(_tenant_id, handle, input) do
    case handle do
      "test.echo" ->
        {:ok, %{context: %{"echo_handle" => handle}, result: input}}

      "test.context_merge" ->
        {:ok, %{context: %{"merged_key" => "merged_value"}}}

      "test.artifacts" ->
        {:ok, %{artifacts: %{"test_result" => %{kind: "test", data: input}}}}

      "test.error" ->
        {:error, :test_capability_failed}

      "test.error_with_context" ->
        {:error, :test_capability_failed, %{context: %{"partial" => "data"}}}

      _ ->
        {:error, {:unknown_capability, handle}}
    end
  end
end
