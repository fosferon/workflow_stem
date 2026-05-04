defmodule WorkflowStem.IR do
  @moduledoc """
  Normalization helpers for workflow specs compiled into IR.

  Delegates common normalizations (initial_state, states, transitions) to
  `Mobus.Stepwise.IR` and adds workflow_stem-specific extensions: multi-profile
  support (flow, fsm), route resolution, and routing maps.
  """

  @type t :: map()

  @spec normalize(map()) :: t()
  def normalize(%{} = spec) do
    spec
    |> Mobus.Stepwise.IR.normalize()
    |> normalize_profile()
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

  defp normalize_routing(spec) do
    routing = Map.get(spec, :routing) || Map.get(spec, "routing") || %{}
    Map.put(spec, :routing, routing)
  end
end

