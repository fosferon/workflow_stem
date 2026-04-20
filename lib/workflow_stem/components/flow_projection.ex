defmodule WorkflowStem.Components.FlowProjection do
  @moduledoc """
  Projection component for `:flow` workflows.

  `:flow` workflows are not interactive, so `available_events` is empty by default.
  """

  alias WorkflowStem.Projection

  @spec call(map(), map()) :: map()
  def call(%{spec: spec, runtime: runtime} = event, _opts) do
    projection = %Projection{
      execution_id: Map.fetch!(runtime, :execution_id),
      profile: :flow,
      current_state: Map.get(runtime, :current_state),
      available_events: [],
      blocked_reasons: Map.get(runtime, :blocked_reasons, %{}),
      breakpoint_hits: Map.get(runtime, :breakpoint_hits, []),
      subscriptions: subscriptions_for(spec, runtime),
      artifacts: Map.get(runtime, :artifacts, %{}),
      ui: Map.get(spec, :ui) || Map.get(spec, "ui"),
      errors: Map.get(runtime, :errors, []),
      trace: Map.get(runtime, :trace, [])
    }

    runtime = Map.put(runtime, :projection, projection)
    event |> Map.put(:runtime, runtime) |> Map.put(:projection, projection)
  end

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
