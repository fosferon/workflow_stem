defmodule WorkflowStem.Components.FlowAction do
  @moduledoc """
  Executes declarative pipeline actions for `:flow` workflows.

  For now, a flow pipeline is a list of steps under `spec.pipeline` (or
  `spec.components`), where each step can reference a capability handle:

      pipeline: [
        %{type: :capability, handle: "my.capability"},
        ...
      ]

  Each capability receives `%{event, payload, current_state: nil, context}` and may
  return:
  - `%{context: %{...}}` to merge context updates
  - `%{result: any}` to replace the carried payload/result
  """

  alias WorkflowStem.Artifacts
  alias WorkflowStem.Capabilities

  @spec call(map(), map()) :: map()
  def call(%{event: "__projection__"} = event, _opts), do: event
  def call(%{status: :error} = event, _opts), do: event

  def call(%{spec: spec, runtime: runtime, event: event_name, payload: payload} = event, _opts) do
    steps = normalize_steps(spec)

    case run_steps(steps, runtime, event_name, payload) do
      {:ok, updated_runtime} ->
        %{event | runtime: updated_runtime}

      {:error, reason, updated_runtime} ->
        updated_runtime =
          updated_runtime
          |> Map.update(:blocked_reasons, %{}, fn reasons -> Map.put(reasons, event_name, reason) end)

        event
        |> Map.put(:status, :error)
        |> Map.put(:error, reason)
        |> Map.put(:runtime, updated_runtime)
    end
  end

  def call(event, _opts), do: Map.put(event, :status, :error) |> Map.put(:error, :invalid_flow_shape)

  defp normalize_steps(spec) do
    raw =
      Map.get(spec, :pipeline) ||
        Map.get(spec, "pipeline") ||
        Map.get(spec, :components) ||
        Map.get(spec, "components") ||
        []

    if is_list(raw) do
      Enum.map(raw, &normalize_step/1)
    else
      []
    end
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_step(%{type: :capability, handle: handle}), do: {:capability, handle}
  defp normalize_step(%{type: "capability", handle: handle}), do: {:capability, handle}
  defp normalize_step(%{"type" => "capability", "handle" => handle}), do: {:capability, handle}
  defp normalize_step(%{"type" => :capability, "handle" => handle}), do: {:capability, handle}
  defp normalize_step(_), do: nil

  defp run_steps([], runtime, event_name, payload) do
    updated_runtime =
      runtime
      |> Map.put(:last_event, {event_name, payload})
      |> Map.put(:last_result, payload)

    {:ok, updated_runtime}
  end

  defp run_steps(steps, runtime, event_name, payload) do
    tenant_id = Map.get(runtime, :tenant_id)
    initial_ctx = Map.get(runtime, :context, %{}) || %{}
    initial_artifacts = Map.get(runtime, :artifacts, %{}) || %{}

    {status, ctx, artifacts, result, trace} =
      Enum.reduce_while(
        steps,
        {:ok, initial_ctx, initial_artifacts, payload, Map.get(runtime, :trace, [])},
        fn
        {:capability, handle}, {:ok, ctx, artifacts, acc, trace} ->
          input = %{event: event_name, payload: acc, current_state: nil, context: ctx, artifacts: artifacts}

          case Capabilities.execute(tenant_id, handle, input) do
            {:ok, %{context: %{} = updates} = out} ->
              next_ctx = Map.merge(ctx, updates)
              next_artifacts = Artifacts.merge(artifacts, artifacts_from(out))
              next_result = maybe_replace_result(acc, out)
              {:cont, {:ok, next_ctx, next_artifacts, next_result, trace ++ [%{kind: :flow, handle: handle}]}}

            {:ok, %{} = out} ->
              next_artifacts = Artifacts.merge(artifacts, artifacts_from(out))
              next_result = maybe_replace_result(acc, out)
              {:cont, {:ok, ctx, next_artifacts, next_result, trace ++ [%{kind: :flow, handle: handle}]}}

            {:ok, other} ->
              {:cont, {:ok, ctx, artifacts, other, trace ++ [%{kind: :flow, handle: handle}]}}

            {:error, reason} ->
              {:halt, {{:error, reason}, ctx, artifacts, acc, trace ++ [%{kind: :flow, handle: handle}]}}
          end
      end)

    case status do
      :ok ->
        updated_runtime =
          runtime
          |> Map.put(:context, ctx)
          |> Map.put(:artifacts, artifacts)
          |> Map.put(:trace, trace)
          |> Map.put(:last_event, {event_name, payload})
          |> Map.put(:last_result, result)

        {:ok, updated_runtime}

      {:error, reason} ->
        updated_runtime =
          runtime
          |> Map.put(:context, ctx)
          |> Map.put(:artifacts, artifacts)
          |> Map.put(:trace, trace)
          |> Map.put(:last_event, {event_name, payload})

        {:error, reason, updated_runtime}
    end
  end

  defp maybe_replace_result(_current, %{result: result}), do: result
  defp maybe_replace_result(_current, %{"result" => result}), do: result
  defp maybe_replace_result(current, _), do: current

  defp artifacts_from(%{artifacts: %{} = artifacts}), do: artifacts
  defp artifacts_from(%{"artifacts" => %{} = artifacts}), do: artifacts
  defp artifacts_from(_), do: %{}
end
