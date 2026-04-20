defmodule WorkflowStem.Components.FsmProjection do
  @moduledoc """
  Projection component for :fsm workflows.

  Produces canonical `WorkflowStem.Projection` from the current runtime state.
  """

  alias WorkflowStem.Projection

  @spec call(map(), map()) :: map()
  def call(%{spec: spec, runtime: runtime} = event, _opts) do
    current = Map.get(runtime, :current_state)

    projection = %Projection{
      execution_id: Map.fetch!(runtime, :execution_id),
      profile: :fsm,
      current_state: current,
      available_events: available_events(spec, current),
      blocked_reasons: Map.get(runtime, :blocked_reasons, %{}),
      breakpoint_hits: Map.get(runtime, :breakpoint_hits, []),
      subscriptions: subscriptions_for(spec, runtime),
      artifacts: Map.get(runtime, :artifacts, %{}),
      ui: ui_for(spec, current, runtime),
      errors: Map.get(runtime, :errors, []),
      trace: Map.get(runtime, :trace, [])
    }

    runtime = Map.put(runtime, :projection, projection)
    event |> Map.put(:runtime, runtime) |> Map.put(:projection, projection)
  end

  defp ui_for(spec, current, runtime) do
    states = Map.get(spec, :states) || %{}
    state_def = Map.get(states, current) || Map.get(states, to_string(current)) || %{}

    ui =
      Map.get(state_def, :ui) ||
        Map.get(state_def, "ui") ||
        %{}

    key = Map.get(ui, :key) || Map.get(ui, "key") || Map.get(state_def, :ui_key) || Map.get(state_def, "ui_key")

    assigns =
      Map.get(ui, :assigns) ||
        Map.get(ui, "assigns") ||
        %{}

    context_assigns = %{context: Map.get(runtime, :context, %{}), state: current}

    if key do
      %{key: key, assigns: Map.merge(assigns, context_assigns)}
    else
      nil
    end
  end

  defp available_events(spec, current) do
    transitions = Map.get(spec, :transitions) || %{}

    transitions
    |> Enum.filter(fn {_event, transition} -> transition_allows_state?(transition, current) end)
    |> Enum.map(fn {event, _} -> event end)
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

  defp subscriptions_for(spec, runtime) do
    base = ["workflow_execution:#{Map.fetch!(runtime, :execution_id)}"]

    declared =
      Map.get(spec, :subscriptions) ||
        Map.get(spec, "subscriptions") ||
        []

    declared
    |> Enum.flat_map(fn
      topic when is_binary(topic) -> [topic]
      %{topic: topic} when is_binary(topic) -> [topic]
      %{"topic" => topic} when is_binary(topic) -> [topic]
      _ -> []
    end)
    |> Enum.map(&interpolate_topic(&1, Map.get(runtime, :context, %{}) || %{}))
    |> Enum.reject(&is_nil/1)
    |> then(&Enum.uniq(base ++ &1))
  end

  defp interpolate_topic(template, context) when is_binary(template) and is_map(context) do
    # Replace "{key}" placeholders from runtime context; drop topic if any placeholder is missing.
    placeholders = Regex.scan(~r/\{([a-zA-Z0-9_]+)\}/, template, capture: :all_but_first)

    Enum.reduce_while(placeholders, template, fn [key], acc ->
      value = Map.get(context, key) || Map.get(context, existing_atom(key))

      if is_binary(value) and byte_size(value) > 0 do
        {:cont, String.replace(acc, "{#{key}}", value)}
      else
        {:halt, nil}
      end
    end)
  end

  defp existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end
end
