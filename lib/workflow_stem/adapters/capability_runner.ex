defmodule WorkflowStem.Adapters.CapabilityRunner do
  @moduledoc """
  Interface adapter for capability execution.

  Capabilities must be addressed by stable identifiers (not Elixir module names),
  and must always preserve tenant lineage (GR-001).
  """

  alias WorkflowStem.Types

  @type capability_handle :: String.t() | atom()

  @callback execute(Types.tenant_id(), capability_handle(), map()) ::
              {:ok, term()} | {:error, term()}
end

