defmodule WorkflowStem.Pipelines.Stepwise do
  @moduledoc """
  Static ALF pipeline for `:stepwise` workflows.

  This pipeline interprets the compiled spec (IR) in-band; we do not generate
  dynamic pipeline modules for disk-loaded workflows.

  The stage order is defined in `Mobus.Stepwise.SpecHelpers.pipeline_stage_modules/0`
  — both the foundation and workflow_stem pipelines reference the same list.
  """

  use ALF.DSL

  alias Mobus.Stepwise.SpecHelpers

  @components for mod <- SpecHelpers.pipeline_stage_modules(), do: stage(mod)

  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> __MODULE__.start(opts)
      _pid -> :ok
    end
  end
end
