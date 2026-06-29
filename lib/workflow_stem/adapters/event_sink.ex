defmodule WorkflowStem.Adapters.EventSink do
  @moduledoc """
  Host adapter for execution event persistence and live publication.

  Events carry an opaque `:metadata` map so hosts can thread metering,
  provenance, and other policy context without changing the shared runner
  contract.
  """

  alias WorkflowStem.Types

  @type event :: %{
          required(:execution_id) => Types.execution_id(),
          required(:kind) => atom(),
          optional(:payload) => map(),
          optional(:metadata) => map(),
          optional(:seq) => non_neg_integer(),
          optional(:at) => DateTime.t()
        }

  @callback append_event(Types.tenant_id(), event()) :: {:ok, event()} | {:error, term()}
  @callback publish_event(event()) :: :ok
  @callback replay(Types.tenant_id(), Types.execution_id(), keyword()) ::
              {:ok, [event()]} | {:error, term()}
end
