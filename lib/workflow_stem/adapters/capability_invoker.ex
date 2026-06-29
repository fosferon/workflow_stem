defmodule WorkflowStem.Adapters.CapabilityInvoker do
  @moduledoc """
  Optional host seam for invoking a capability with host context.

  `WorkflowStem.Adapters.CapabilityRunner` remains the engine-level adapter.
  This behaviour exists for runner-host integrations that need to thread
  opaque metering, provenance, or dispatch context around capability execution.
  """

  alias WorkflowStem.Types

  @callback invoke(Types.tenant_id(), term(), map(), map()) ::
              {:ok, term()} | {:wait, term()} | {:error, term()}
end
