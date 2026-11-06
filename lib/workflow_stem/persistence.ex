defmodule WorkflowStem.Persistence do
  @moduledoc """
  Persistence adapter facade for workflow executions and checkpoints.

  Reads the adapter module from `:workflow_stem, :persistence_adapter`
  (a module implementing `WorkflowStem.Adapters.PersistenceAdapter`).
  With no adapter configured, persistence is disabled:

    * `save_execution/2` and `save_checkpoint/3` return `{:ok, :skipped}`;
    * `get_execution/2` returns `{:error, :persistence_disabled}`;
    * `list_executions/2` returns `{:ok, []}` — indistinguishable from a
      tenant with no executions, so check `enabled?/0` when that matters.

  Configure an adapter with:

  ```elixir
  config :workflow_stem, persistence_adapter: MyApp.WorkflowPersistence
  ```
  """

  @spec adapter() :: module() | nil
  def adapter do
    Application.get_env(:workflow_stem, :persistence_adapter)
  end

  @doc """
  Returns `true` when a configured adapter module implements
  `save_execution/2`. Loads the adapter module if it is not loaded yet.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    mod = adapter()

    is_atom(mod) and not is_nil(mod) and Code.ensure_loaded?(mod) and
      function_exported?(mod, :save_execution, 2)
  end

  @spec save_execution(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def save_execution(tenant_id, execution) do
    case adapter() do
      nil -> {:ok, :skipped}
      mod when is_atom(mod) -> mod.save_execution(tenant_id, execution)
    end
  end

  @spec get_execution(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_execution(tenant_id, execution_id) do
    case adapter() do
      nil -> {:error, :persistence_disabled}
      mod when is_atom(mod) -> mod.get_execution(tenant_id, execution_id)
    end
  end

  @spec save_checkpoint(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def save_checkpoint(tenant_id, execution_id, checkpoint) do
    case adapter() do
      nil -> {:ok, :skipped}
      mod when is_atom(mod) -> mod.save_checkpoint(tenant_id, execution_id, checkpoint)
    end
  end

  @spec list_executions(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_executions(tenant_id, opts) do
    case adapter() do
      nil -> {:ok, []}
      mod when is_atom(mod) -> mod.list_executions(tenant_id, opts)
    end
  end
end
