defmodule WorkflowStem.Compiler.Resolvers do
  @moduledoc """
  Internal ALF-switch resolvers used by pipelines synthesized via
  `WorkflowStem.Compiler.components_for_engine/1`.

  These are referenced by `defdelegate` on the runtime-compiled pipeline
  module so ALF's `switch` can resolve them in the usual way
  (`apply(pipeline_mod, name, [event, opts])`).
  """

  @doc """
  Resolver for the synthetic `:__current_state__` switch that dispatches
  per-event routing based on the workflow's current state.

  The ALF event arriving at the switch carries the full event map we
  hand to `WorkflowStem.Pipelines.Stepwise` — i.e. `%{runtime: ..., spec: ...}`.
  The current state lives on `runtime.current_state`.
  """
  @spec current_state(map(), keyword()) :: atom() | String.t()
  def current_state(%{runtime: %{current_state: state}}, _opts), do: state
  def current_state(%{"runtime" => %{"current_state" => state}}, _opts), do: state
end
