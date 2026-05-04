defmodule WorkflowStem.Components.StepwiseProjection do
  @moduledoc """
  Wraps `Mobus.Stepwise.Components.StepwiseProjection` and converts the
  resulting `Mobus.Stepwise.Projection` into `WorkflowStem.Projection`.

  Delegates all projection logic (ordered_steps, available_events, ui_for,
  subscriptions_for, build_extensions) to the foundation, then wraps the
  struct for workflow_stem consumers.

  See `Mobus.Stepwise.Components.StepwiseProjection` for the underlying
  implementation.
  """

  alias WorkflowStem.Projection

  @spec call(map(), map()) :: map()
  def call(event, opts) do
    event
    |> Mobus.Stepwise.Components.StepwiseProjection.call(opts)
    |> convert_projection()
  end

  defp convert_projection(%{runtime: %{projection: %Mobus.Stepwise.Projection{} = src}} = event) do
    wrapped = %Projection{
      execution_id: src.execution_id,
      profile: src.profile,
      current_state: src.current_state,
      available_events: src.available_events,
      blocked_reasons: src.blocked_reasons,
      breakpoint_hits: src.breakpoint_hits,
      subscriptions: src.subscriptions,
      artifacts: src.artifacts,
      ui: src.ui,
      errors: src.errors,
      trace: src.trace,
      extensions: src.extensions
    }

    runtime = Map.put(event.runtime, :projection, wrapped)

    event
    |> Map.put(:runtime, runtime)
    |> Map.put(:projection, wrapped)
  end

  # Fallback: runtime has no projection or it's already the right struct
  defp convert_projection(event), do: event
end
