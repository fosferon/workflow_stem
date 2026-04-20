defmodule WorkflowStem.Components.FsmTransition do
  @moduledoc """
  FSM semantic transition component.

  Applies the `from -> to` transition and records history/trace.
  """

  require Logger

  @spec call(map(), map()) :: map()
  def call(%{skip_transition: true} = event, _opts), do: event
  def call(%{status: :error} = event, _opts), do: event

  def call(%{spec: spec, runtime: runtime, event: event_name, payload: payload} = event, _opts)
      when is_map(payload) do
    transitions = Map.get(spec, :transitions) || %{}

    transition =
      Map.get(transitions, event_name) ||
        Map.get(transitions, to_string(event_name)) ||
        Map.get(transitions, normalize_event_key(event_name))

    to_state = Map.get(transition || %{}, :to) || Map.get(transition || %{}, "to")
    from_state = Map.get(runtime, :current_state)

    runtime =
      runtime
      |> Map.put(:current_state, to_state)
      |> Map.update(:context, %{}, fn ctx -> Map.merge(ctx, payload) end)
      |> Map.update(:history, [], fn hist ->
        hist ++ [%{event: event_name, from: from_state, to: to_state, at: DateTime.utc_now()}]
      end)
      |> Map.update(:trace, [], fn trace ->
        trace ++ [%{kind: :transition, event: event_name, from: from_state, to: to_state}]
      end)

    _ = maybe_append_comm_bus(runtime, event_name, payload)

    wait_cfg = Map.get(transition || %{}, :wait) || Map.get(transition || %{}, "wait")

    event
    |> Map.put(:runtime, runtime)
    |> maybe_put_wait(wait_cfg)
  end

  def call(event, _opts), do: Map.put(event, :status, :error) |> Map.put(:error, :invalid_transition_shape)

  defp maybe_put_wait(event, nil), do: event
  defp maybe_put_wait(event, false), do: event
  defp maybe_put_wait(event, %{} = cfg), do: Map.put(event, :wait, cfg)
  defp maybe_put_wait(event, other), do: Map.put(event, :wait, %{value: other})

  defp normalize_event_key(event) when is_atom(event), do: event
  defp normalize_event_key(event) when is_binary(event) do
    try do
      String.to_existing_atom(event)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_event_key(_), do: nil

  defp maybe_append_comm_bus(runtime, event_name, payload) do
    case comm_bus_adapter() do
      nil ->
        :ok

      adapter when is_atom(adapter) ->
        if Map.has_key?(runtime, :execution_id) do
          execution_id = Map.get(runtime, :execution_id)
          data = Map.get(payload, "discovery") || payload

          content =
            data
            |> Map.drop(["_csrf_token", "_target", "_method", "event"])
            |> format_payload()

          if is_binary(content) and content != "" do
            case adapter.append_message(execution_id, :user, content, %{event: event_name}) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.debug("[CommBus] append failed: #{inspect(reason)}")
            end
          end
        end
    end

    :ok
  end

  defp comm_bus_adapter do
    Application.get_env(:workflow_stem, :comm_bus_adapter)
  end

  defp format_payload(%{} = payload) when map_size(payload) > 0 do
    payload
    |> Enum.map(fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> Enum.join("\n")
  end

  defp format_payload(_), do: ""

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_value(value) when is_map(value) or is_list(value), do: inspect(value)
  defp format_value(_), do: ""
end
