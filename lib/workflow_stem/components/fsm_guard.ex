defmodule WorkflowStem.Components.FsmGuard do
  @moduledoc """
  FSM semantic guard component.

  Validates that an event is allowed from the current state (available events gating).
  """

  @spec call(map(), map()) :: map()
  def call(%{skip_guard: true} = event, _opts), do: event
  def call(%{status: :error} = event, _opts), do: event

  def call(%{spec: spec, runtime: runtime, event: event_name} = event, _opts) do
    current = Map.get(runtime, :current_state)

    case allowed?(spec, current, event_name) do
      :ok ->
        event

      {:error, reason} ->
        runtime =
          runtime
          |> Map.update(:blocked_reasons, %{}, fn reasons ->
            Map.put(reasons, event_name, reason)
          end)

        event
        |> Map.put(:status, :error)
        |> Map.put(:error, reason)
        |> Map.put(:runtime, runtime)
    end
  end

  def call(event, _opts), do: Map.put(event, :status, :error) |> Map.put(:error, :invalid_event_shape)

  defp allowed?(spec, current_state, event_name) do
    transitions = Map.get(spec, :transitions) || %{}

    transition =
      Map.get(transitions, event_name) ||
        Map.get(transitions, to_string(event_name)) ||
        Map.get(transitions, normalize_event_key(event_name))

    cond do
      is_nil(transition) ->
        {:error, {:invalid_event, event_name, current_state}}

      transition_allows_state?(transition, current_state) ->
        :ok

      true ->
        {:error, {:event_blocked, event_name, current_state}}
    end
  end

  defp transition_allows_state?(%{from: from}, current), do: state_in_from?(from, current)
  defp transition_allows_state?(%{"from" => from}, current), do: state_in_from?(from, current)
  defp transition_allows_state?(_other, _current), do: false

  defp state_in_from?(from, current) when is_list(from) do
    Enum.any?(from, &equivalent_state?(&1, current))
  end

  defp state_in_from?(from, current), do: equivalent_state?(from, current)

  defp equivalent_state?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp equivalent_state?(a, b) when is_atom(a) and is_atom(b), do: a == b
  defp equivalent_state?(a, b) when is_atom(a) and is_binary(b), do: Atom.to_string(a) == b
  defp equivalent_state?(a, b) when is_binary(a) and is_atom(b), do: a == Atom.to_string(b)
  defp equivalent_state?(_a, _b), do: false

  defp normalize_event_key(event) when is_atom(event), do: event
  defp normalize_event_key(event) when is_binary(event) do
    try do
      String.to_existing_atom(event)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_event_key(_), do: nil
end
