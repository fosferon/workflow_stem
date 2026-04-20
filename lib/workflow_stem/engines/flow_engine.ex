defmodule WorkflowStem.Engines.FlowEngine do
  @moduledoc """
  ALF-backed engine for `:flow` workflows.

  Flow workflows are pure data pipelines: they accept arbitrary input events and
  run a sequence of transformations, producing a result and accumulating trace.

  The `:flow` profile intentionally does not provide FSM-style state gating.
  """

  @behaviour WorkflowStem.EngineBehaviour

  alias WorkflowStem.IR
  alias WorkflowStem.Pipelines.Flow, as: FlowPipeline
  alias WorkflowStem.Components.FlowProjection
  alias WorkflowStem.Projection
  require Logger

  @type runtime :: %{
          required(:execution_id) => String.t(),
          required(:tenant_id) => String.t(),
          required(:spec) => map(),
          optional(:context) => map(),
          optional(:trace) => list(),
          optional(:blocked_reasons) => map(),
          optional(:breakpoint_hits) => list(),
          optional(:last_event) => {term(), term()} | nil,
          optional(:last_result) => term(),
          optional(:errors) => [map()],
          optional(:projection) => Projection.t()
        }

  @impl true
  def init(spec, runtime_context) when is_map(spec) and is_map(runtime_context) do
    with {:ok, tenant_id} <- fetch_tenant_id(runtime_context),
         {:ok, execution_id} <- fetch_execution_id(runtime_context),
         :ok <- ensure_pipeline(runtime_context) do
      ir = IR.normalize(spec)

      runtime = %{
        execution_id: execution_id,
        tenant_id: tenant_id,
        spec: ir,
        context: Map.get(runtime_context, :initial_context, %{}) || %{},
        artifacts: %{},
        trace: [],
        blocked_reasons: %{},
        breakpoint_hits: [],
        last_event: nil,
        last_result: nil
      }

      {:ok, compute_projection(runtime)}
    end
  end

  @impl true
  def handle_event(runtime, event, payload)
      when is_map(runtime) and (is_atom(event) or is_binary(event)) and is_map(payload) do
    :ok = ensure_pipeline(%{})

    input = %{
      spec: runtime.spec,
      runtime: Map.delete(runtime, :projection),
      event: event,
      payload: payload,
      status: :ok
    }

    case call_pipeline(input) do
      {:ok, %{status: :error, error: reason, runtime: updated}} ->
        {:error, reason, compute_projection(updated)}

      {:ok, %{runtime: updated}} ->
        {:ok, compute_projection(updated)}

      {:error, reason} ->
        {:error, reason, compute_projection(runtime)}
    end
  end

  @impl true
  def get_state(%{projection: %Projection{} = projection}), do: projection

  def get_state(runtime) when is_map(runtime) do
    runtime = compute_projection(runtime)

    case runtime do
      %{projection: %Projection{} = projection} -> projection
      _ -> runtime |> build_projection() |> Map.fetch!(:projection)
    end
  end

  @impl true
  def checkpoint(runtime) when is_map(runtime) do
    runtime
    |> Map.drop([:projection])
    |> Map.take([
      :execution_id,
      :tenant_id,
      :spec,
      :context,
      :artifacts,
      :trace,
      :blocked_reasons,
      :breakpoint_hits,
      :last_event,
      :last_result
    ])
  end

  @impl true
  def restore(spec, checkpoint, runtime_context)
      when is_map(spec) and is_map(checkpoint) and is_map(runtime_context) do
    with {:ok, tenant_id} <- fetch_tenant_id(runtime_context),
         :ok <- ensure_pipeline(runtime_context) do
      ir = IR.normalize(spec)

      execution_id =
        Map.get(checkpoint, :execution_id) ||
          Map.get(checkpoint, "execution_id") ||
          Map.get(runtime_context, :execution_id) ||
          Map.get(runtime_context, "execution_id") ||
          "stem-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

      runtime = %{
        execution_id: execution_id,
        tenant_id: tenant_id,
        spec: ir,
        context: Map.get(checkpoint, :context) || Map.get(checkpoint, "context") || %{},
        artifacts: Map.get(checkpoint, :artifacts) || Map.get(checkpoint, "artifacts") || %{},
        trace: Map.get(checkpoint, :trace) || Map.get(checkpoint, "trace") || [],
        blocked_reasons: Map.get(checkpoint, :blocked_reasons) || Map.get(checkpoint, "blocked_reasons") || %{},
        breakpoint_hits: Map.get(checkpoint, :breakpoint_hits) || Map.get(checkpoint, "breakpoint_hits") || [],
        last_event: Map.get(checkpoint, :last_event) || Map.get(checkpoint, "last_event"),
        last_result: Map.get(checkpoint, :last_result) || Map.get(checkpoint, "last_result")
      }

      {:ok, compute_projection(runtime)}
    end
  end

  defp ensure_pipeline(runtime_context) do
    opts =
      case Map.get(runtime_context, :sync) do
        true -> [sync: true]
        _ -> []
      end

    case FlowPipeline.ensure_started(opts) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp call_pipeline(input) do
    case FlowPipeline.call(input) do
      %ALF.IP{event: out} -> {:ok, out}
      %ALF.ErrorIP{error: error} -> {:error, error}
      %{} = out -> {:ok, out}
      other -> {:error, {:unexpected_pipeline_result, other}}
    end
  end

  defp compute_projection(runtime) do
    input = %{
      spec: runtime.spec,
      runtime: Map.delete(runtime, :projection),
      event: "__projection__",
      payload: %{},
      status: :ok
    }

    case call_pipeline(input) do
      {:ok, %{runtime: updated}} ->
        if match?(%Projection{}, Map.get(updated, :projection)) do
          updated
        else
          error = projection_error(:missing_projection, updated, input.event)
          log_projection_error(error)
          build_projection(updated, [error])
        end

      {:error, reason} ->
        error = projection_error(reason, runtime, input.event)
        log_projection_error(error)
        build_projection(runtime, [error])
    end
  end

  defp build_projection(runtime, errors \\ []) do
    runtime = append_errors(runtime, errors)
    event = %{spec: runtime.spec, runtime: Map.delete(runtime, :projection)}

    case FlowProjection.call(event, %{}) do
      %{runtime: updated} -> updated
      _ -> runtime
    end
  end

  defp append_errors(runtime, errors) when is_list(errors) and errors != [] do
    Map.update(runtime, :errors, errors, fn existing -> existing ++ errors end)
  end

  defp append_errors(runtime, _errors), do: runtime

  defp projection_error(reason, runtime, event) do
    %{
      type: :pipeline_error,
      reason: reason,
      engine: __MODULE__,
      event: event,
      execution_id: Map.get(runtime, :execution_id),
      timestamp: DateTime.utc_now()
    }
  end

  defp log_projection_error(error) do
    Logger.warning("Workflow stem projection pipeline failed: #{inspect(error)}")
  end

  defp fetch_tenant_id(runtime_context) do
    case Map.get(runtime_context, :tenant_id) || Map.get(runtime_context, "tenant_id") do
      nil -> {:error, :missing_tenant_id}
      tid -> {:ok, tid}
    end
  end

  defp fetch_execution_id(runtime_context) do
    case Map.get(runtime_context, :execution_id) || Map.get(runtime_context, "execution_id") do
      nil -> {:ok, "stem-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))}
      id -> {:ok, id}
    end
  end
end
