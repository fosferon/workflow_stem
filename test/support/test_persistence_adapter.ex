defmodule WorkflowStem.TestPersistenceAdapter do
  @moduledoc false
  # Compiled to a .beam on the test code path, so a test can unload it and
  # check that Persistence.enabled?/0 loads it again.
  @behaviour WorkflowStem.Adapters.PersistenceAdapter

  @impl true
  def save_execution(tenant_id, execution), do: {:ok, %{tenant: tenant_id, saved: execution}}

  @impl true
  def get_execution(tenant_id, execution_id), do: {:ok, %{tenant: tenant_id, id: execution_id}}

  @impl true
  def save_checkpoint(tenant_id, execution_id, checkpoint),
    do: {:ok, %{tenant: tenant_id, id: execution_id, checkpoint: checkpoint}}

  @impl true
  def list_executions(tenant_id, opts), do: {:ok, [%{tenant: tenant_id, opts: opts}]}
end
