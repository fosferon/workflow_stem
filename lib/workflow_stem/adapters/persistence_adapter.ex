defmodule WorkflowStem.Adapters.PersistenceAdapter do
  @moduledoc """
  Interface adapter for execution persistence and checkpoint storage.

  The stem runtime is shared across tenants; persistence must remain tenant-scoped.
  """

  alias WorkflowStem.Types

  @callback save_execution(Types.tenant_id(), map()) :: {:ok, map()} | {:error, term()}
  @callback get_execution(Types.tenant_id(), Types.execution_id()) :: {:ok, map()} | {:error, term()}

  @callback save_checkpoint(Types.tenant_id(), Types.execution_id(), map()) ::
              {:ok, map()} | {:error, term()}

  @callback list_executions(Types.tenant_id(), map()) :: {:ok, [map()]} | {:error, term()}
end

