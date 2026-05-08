defmodule WorkflowStem.Pipelines.Fsm do
  @moduledoc """
  Static ALF pipeline for the `:fsm` profile.

  This pipeline interprets compiled IR; it is shared across workflows/executions.
  Per-execution state is carried in-band in the event payload (no pipeline-module generation).
  """

  use ALF.DSL

  alias WorkflowStem.Components.FsmAction
  alias WorkflowStem.Components.FsmBreakpoint
  alias WorkflowStem.Components.FsmGuard
  alias WorkflowStem.Components.FsmProjection
  alias WorkflowStem.Components.FsmTransition

  @components [
    stage(FsmGuard),
    stage(FsmAction),
    stage(FsmTransition),
    stage(FsmBreakpoint),
    stage(FsmProjection)
  ]

  @spec ensure_started(keyword()) :: :ok
  def ensure_started(opts \\ []) do
    start(opts)
  end
end
