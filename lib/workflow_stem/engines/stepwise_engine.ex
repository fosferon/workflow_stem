defmodule WorkflowStem.Engines.StepwiseEngine do
  @moduledoc """
  Shim over `Mobus.Stepwise.Engine` for `:stepwise` workflows.

  Since workflow_stem v0.2.0, this module delegates to the foundation
  engine in `mobus_stepwise`. Consumers gain transitively:

    * telemetry span wrapping on all lifecycle phases
    * `{:wait, ...}` short-circuit in advance / entry-action stages
    * transition-policy hooks
    * projection-enricher hooks
    * `meta` passthrough to capability input
    * init-error propagation (`{:error, {:initial_entry_action_failed, ...}}`)

  ## Pipeline indirection

  The engine reads `pipeline_mod` from `runtime_context` (set by
  `WorkflowStem.Registry` for per-agent compiled pipelines). When no
  pipeline is injected, defaults to `WorkflowStem.Pipelines.Stepwise`,
  not the foundation's static pipeline, because workflow_stem components
  carry additional action types (e.g. `:conversation`).

  ## Adapter configuration bridging

  On application start, workflow_stem copies its own adapter config keys
  (`:workflow_stem, :capability_runner_adapter` and
  `:workflow_stem, :capability_runner_strict`) into mobus_stepwise's
  application env so the foundation engine picks them up transparently.
  """

  @behaviour WorkflowStem.EngineBehaviour

  alias Mobus.Stepwise.Engine, as: Foundation
  alias WorkflowStem.Projection
  alias WorkflowStem.Pipelines.Stepwise, as: DefaultPipeline

  # ── Inject workflow_stem default pipeline ──────────────────────────

  # The foundation engine resolves its own default
  # (Mobus.Stepwise.Pipeline.Stepwise) when no :pipeline_mod key is
  # present. We override that here so consumers that don't inject a
  # pipeline get the workflow_stem variant with conversation support.
  defp inject_default_pipeline(runtime_context) do
    unless Map.has_key?(runtime_context, :pipeline_mod) or
             Map.has_key?(runtime_context, "pipeline_mod") do
      Map.put(runtime_context, :pipeline_mod, DefaultPipeline)
    else
      runtime_context
    end
  end

  # ── Projection conversion ──────────────────────────────────────────

  defp convert_projection(%Mobus.Stepwise.Projection{} = src) do
    %Projection{
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
  end

  defp convert_projection(other), do: other

  defp convert_runtime(%{projection: %Mobus.Stepwise.Projection{} = proj} = rt) do
    %{rt | projection: convert_projection(proj)}
  end

  defp convert_runtime(rt), do: rt

  # ── Delegation ─────────────────────────────────────────────────────

  @impl true
  def init(spec, runtime_context) do
    runtime_context = inject_default_pipeline(runtime_context)

    case Foundation.init(spec, runtime_context) do
      {:ok, runtime} -> {:ok, convert_runtime(runtime)}
      {:error, {:initial_entry_action_failed, reason, runtime}} ->
        {:error, {:initial_entry_action_failed, reason, convert_runtime(runtime)}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_event(runtime, event, payload) do
    # Strip the WorkflowStem projection so the foundation engine sees a clean
    # runtime. We'll convert back on the way out.
    runtime = strip_projection(runtime)

    case Foundation.handle_event(runtime, event, payload) do
      {:ok, runtime} -> {:ok, convert_runtime(runtime)}
      {:wait, runtime, cfg} -> {:wait, convert_runtime(runtime), cfg}
      {:error, reason, runtime} -> {:error, reason, convert_runtime(runtime)}
    end
  end

  @impl true
  def get_state(runtime) do
    runtime = strip_projection(runtime)
    Foundation.get_state(runtime) |> convert_projection()
  end

  @impl true
  defdelegate checkpoint(runtime), to: Foundation

  @impl true
  def restore(spec, checkpoint, runtime_context) do
    runtime_context = inject_default_pipeline(runtime_context)

    case Foundation.restore(spec, checkpoint, runtime_context) do
      {:ok, runtime} -> {:ok, convert_runtime(runtime)}
      {:error, _} = err -> err
    end
  end

  # Remove WorkflowStem.Projection from runtime before passing to foundation,
  # since the foundation expects to build its own Mobus.Stepwise.Projection.
  defp strip_projection(%{projection: %Projection{}} = rt) do
    Map.delete(rt, :projection)
  end

  defp strip_projection(rt), do: rt
end
