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

  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case start(opts) do
      :ok -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_started, _pid, _info}} -> :ok
      other -> other
    end
  end
end
