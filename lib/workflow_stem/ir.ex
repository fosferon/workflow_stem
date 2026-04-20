defmodule WorkflowStem.IR do
  @moduledoc """
  Normalization helpers for workflow specs compiled into IR.

  Phase 2: keep IR as a data-map, but normalize shapes to reduce downstream conditionals.
  """

  @type t :: map()

  @spec normalize(map()) :: t()
  def normalize(%{} = spec) do
    spec
    |> normalize_profile()
    |> normalize_initial_state()
    |> normalize_states()
    |> normalize_transitions()
    |> normalize_routing()
  end

  @doc """
  Returns the route tuple declared on a state, or `nil` if the state has none.

  Route tuples mirror ALF's DSL macros 1:1 (see `WorkflowStem.SpecBehaviour`):
    * `{:stage, target, opts}`, `{:switch, name, %{branch_key => body}}`,
      `{:composer, module, opts}`, `{:goto, name, opts}`,
      `{:goto_point, name}`, `{:done, name, opts}`, `{:dead_end, name}`,
      `{:from, module, opts}`, `{:plug_with, module, body}`, `{:tbd, name}`

  A state's `:route` may also be a LIST of such tuples — return type
  reflects that with `list()` as a possible shape.
  """
  @spec route_for_state(t(), atom() | String.t()) :: tuple() | list() | nil
  def route_for_state(%{} = spec, state_name) do
    spec
    |> Map.get(:states, %{})
    |> Map.get(state_name)
    |> case do
      %{route: route} -> route
      %{"route" => route} -> route
      _ -> nil
    end
  end

  @doc """
  Returns the `{module, function}` resolver tuple for a named route, or `nil`.
  """
  @spec routing_for(t(), atom()) :: {module(), atom()} | nil
  def routing_for(%{} = spec, route_name) do
    spec
    |> Map.get(:routing, %{})
    |> Map.get(route_name)
  end

  defp normalize_profile(spec) do
    profile = Map.get(spec, :profile) || Map.get(spec, "profile")

    profile =
      case profile do
        "flow" -> :flow
        "fsm" -> :fsm
        "stepwise" -> :stepwise
        other -> other
      end

    Map.put(spec, :profile, profile)
  end

  defp normalize_initial_state(spec) do
    initial = Map.get(spec, :initial_state) || Map.get(spec, "initial_state")
    Map.put(spec, :initial_state, initial)
  end

  defp normalize_states(spec) do
    states = Map.get(spec, :states) || Map.get(spec, "states") || %{}
    Map.put(spec, :states, states)
  end

  defp normalize_transitions(spec) do
    transitions = Map.get(spec, :transitions) || Map.get(spec, "transitions") || %{}

    transitions =
      case transitions do
        %{} -> transitions
        list when is_list(list) -> Map.new(list, fn {k, v} -> {k, v} end)
        other -> other
      end

    Map.put(spec, :transitions, transitions)
  end

  defp normalize_routing(spec) do
    routing = Map.get(spec, :routing) || Map.get(spec, "routing") || %{}
    Map.put(spec, :routing, routing)
  end
end

