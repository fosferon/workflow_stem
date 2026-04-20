defmodule WorkflowStem.Pipelines.Flow do
  @moduledoc """
  Static ALF pipeline for the `:flow` profile.

  Flow workflows are non-interactive pipelines: the workflow spec describes a
  list of transformations (currently expressed as capability handles), and the
  engine runs them sequentially. No FSM gating semantics are applied.
  """

  use ALF.DSL

  alias WorkflowStem.Components.FlowAction
  alias WorkflowStem.Components.FlowProjection

  @components [
    stage(FlowAction),
    stage(FlowProjection)
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

