defmodule WorkflowStem.Capabilities do
  @moduledoc false

  @spec adapter() :: module() | nil
  def adapter do
    Application.get_env(:workflow_stem, :capability_runner_adapter)
  end

  @spec enabled?() :: boolean()
  def enabled? do
    is_atom(adapter()) and function_exported?(adapter(), :execute, 3)
  end

  @spec execute(String.t(), String.t() | atom(), map()) :: {:ok, term()} | {:error, term()}
  def execute(tenant_id, capability_handle, input) when is_binary(tenant_id) and is_map(input) do
    case adapter() do
      nil -> {:error, :capability_runner_disabled}
      mod when is_atom(mod) -> mod.execute(tenant_id, capability_handle, input)
    end
  end
end

