defmodule WorkflowStem.Components.FsmProjection do
  @moduledoc """
  Projection component for :fsm workflows.

  Produces canonical `WorkflowStem.Projection` from the current runtime state.
  """

  alias Mobus.Stepwise.ProjectionHelpers
  alias Mobus.Stepwise.SpecHelpers
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
      subscriptions: ProjectionHelpers.subscriptions_for(spec, runtime),
      artifacts: Map.get(runtime, :artifacts, %{}),
      ui: ProjectionHelpers.ui_for(spec, current, runtime),
      errors: Map.get(runtime, :errors, []),
      trace: Map.get(runtime, :trace, []),
      extensions: ProjectionHelpers.build_extensions(spec, runtime)
    }

    runtime = Map.put(runtime, :projection, projection)
    event |> Map.put(:runtime, runtime) |> Map.put(:projection, projection)
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
    Enum.any?(from, &SpecHelpers.equivalent_state?(&1, current))
  end

  defp state_in_from?(from, current), do: SpecHelpers.equivalent_state?(from, current)
end
