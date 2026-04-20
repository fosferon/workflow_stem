defmodule WorkflowStem.Pipelines.Stepwise do
  @moduledoc """
  Static ALF pipeline for `:stepwise` workflows.

  This pipeline interprets the compiled spec (IR) in-band; we do not generate
  dynamic pipeline modules for disk-loaded workflows.
  """

  use ALF.DSL

  alias WorkflowStem.Components.FsmBreakpoint
  alias WorkflowStem.Components.StepwiseAction
  alias WorkflowStem.Components.StepwiseAdvance
  alias WorkflowStem.Components.StepwiseEntryAction
  alias WorkflowStem.Components.StepwiseContextMerge
  alias WorkflowStem.Components.StepwiseProjection

  @components [
    stage(StepwiseContextMerge),
    stage(StepwiseAction),
    stage(StepwiseAdvance),
    stage(StepwiseEntryAction),
    stage(FsmBreakpoint),
    stage(StepwiseProjection)
  ]

  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> __MODULE__.start(opts)
      _pid -> :ok
    end
  end
end
