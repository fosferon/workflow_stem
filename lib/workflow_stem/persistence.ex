defmodule WorkflowStem.Persistence do
  @moduledoc false

  @spec adapter() :: module() | nil
  def adapter do
    Application.get_env(:workflow_stem, :persistence_adapter)
  end

  @spec enabled?() :: boolean()
  def enabled? do
    is_atom(adapter()) and function_exported?(adapter(), :save_execution, 2)
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
