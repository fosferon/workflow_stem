defmodule WorkflowStem.EventLog do
  @moduledoc """
  Append-then-publish event log facade for observable executions.

  Durability belongs to the host adapter. The facade gives the runner one
  stable contract: append the canonical event first, then publish the persisted
  event for live subscribers. Late subscribers replay through the same adapter.
  """

  alias WorkflowStem.Adapters.EventSink

  @type event :: EventSink.event()

  @spec emit(module() | nil, String.t(), event()) :: {:ok, event()} | {:error, term()}
  def emit(nil, _tenant_id, event), do: {:ok, normalize_event(event)}

  def emit(sink, tenant_id, event) when is_atom(sink) and is_binary(tenant_id) do
    event = normalize_event(event)

    case sink.append_event(tenant_id, event) do
      {:ok, persisted} ->
        _ = sink.publish_event(persisted)
        {:ok, persisted}

      {:error, reason} = error ->
        _ = sink.publish_event(event)
        _ = reason
        error
    end
  end

  @spec replay(module() | nil, String.t(), String.t(), keyword()) ::
          {:ok, [event()]} | {:error, term()}
  def replay(sink, tenant_id, execution_id, opts \\ [])

  def replay(nil, _tenant_id, _execution_id, _opts), do: {:ok, []}

  def replay(sink, tenant_id, execution_id, opts)
      when is_atom(sink) and is_binary(tenant_id) and is_binary(execution_id) do
    sink.replay(tenant_id, execution_id, opts)
  end

  defp normalize_event(event) when is_map(event) do
    event
    |> Map.put_new(:payload, %{})
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:at, DateTime.utc_now())
  end
end
