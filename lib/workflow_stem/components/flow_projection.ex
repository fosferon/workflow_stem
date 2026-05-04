defmodule WorkflowStem.Components.FlowProjection do
  @moduledoc """
  Projection component for `:flow` workflows.

  `:flow` workflows are not interactive, so `available_events` is empty by default.
  """

  alias Mobus.Stepwise.ProjectionHelpers
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
      subscriptions: ProjectionHelpers.subscriptions_for(spec, runtime),
      artifacts: Map.get(runtime, :artifacts, %{}),
      ui: Map.get(spec, :ui) || Map.get(spec, "ui"),
      errors: Map.get(runtime, :errors, []),
      trace: Map.get(runtime, :trace, []),
      extensions: ProjectionHelpers.build_extensions(spec, runtime)
    }

    runtime = Map.put(runtime, :projection, projection)
    event |> Map.put(:runtime, runtime) |> Map.put(:projection, projection)
  end
end
