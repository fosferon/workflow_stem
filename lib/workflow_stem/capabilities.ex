defmodule WorkflowStem.Capabilities do
  @moduledoc """
  Capability runner adapter for workflow_stem consumers.

  ## Relationship to the foundation

  The stepwise engine path delegates to `Mobus.Stepwise.Engine`, which uses
  `Mobus.Stepwise.Capabilities` internally. That module reads from
  `:mobus_stepwise` config — bridged at startup by `WorkflowStem.Application`.

  This module (`WorkflowStem.Capabilities`) remains for the **FSM and Flow
  engine paths**, which have their own capability execution flows. It reads
  from `:workflow_stem` config directly (not bridged).

  Consumers that only use the stepwise engine can ignore this module;
  configure `:workflow_stem, :capability_runner_adapter` and the bridge
  handles the rest. FSM/Flow consumers call `execute/3` here directly.
  """

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

