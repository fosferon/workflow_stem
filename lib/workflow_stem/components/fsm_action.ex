defmodule WorkflowStem.Components.FsmAction do
  @moduledoc """
  Executes declarative transition actions.

  Phase 4: supports `:capability` actions and `:save_step` actions.
  """

  alias WorkflowStem.Artifacts
  alias WorkflowStem.Capabilities

  @spec call(map(), map()) :: map()
  def call(%{status: :error} = event, _opts), do: event

  def call(%{spec: spec, runtime: runtime, event: event_name, payload: payload} = event, _opts)
      when is_map(payload) do
    transition = resolve_transition(spec, event_name)

    case resolve_action(transition) do
      nil ->
        event

      {:save_step, step_key} ->
        runtime =
          runtime
          |> Map.put(:context, apply_save_step(runtime, step_key, payload))
          |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: :save_step, key: step_key}] end)

        %{event | runtime: runtime}

      {:capability, handle} ->
        tenant_id = Map.get(runtime, :tenant_id)

        input = %{
          event: event_name,
          payload: payload,
          current_state: Map.get(runtime, :current_state),
          context: Map.get(runtime, :context, %{}),
          artifacts: Map.get(runtime, :artifacts, %{}) || %{}
        }

        case Capabilities.execute(tenant_id, handle, input) do
          {:ok, %{context: %{} = context_updates} = out} ->
            runtime =
              runtime
              |> Map.update(:context, %{}, fn ctx -> Map.merge(ctx, context_updates) end)
              |> Map.update(:artifacts, %{}, fn artifacts -> Artifacts.merge(artifacts, artifacts_from(out)) end)
              |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: handle}] end)
              |> maybe_put_action_result(out)

            %{event | runtime: runtime}

          {:ok, %{} = out} ->
            runtime = runtime |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: handle}] end)
            %{event | runtime: runtime} |> Map.put(:action_result, out)

          {:ok, other} ->
            runtime = runtime |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: handle}] end)
            %{event | runtime: runtime} |> Map.put(:action_result, other)

          {:error, reason} ->
            runtime =
              runtime
              |> Map.update(:blocked_reasons, %{}, fn reasons -> Map.put(reasons, event_name, reason) end)

            event
            |> Map.put(:status, :error)
            |> Map.put(:error, reason)
            |> Map.put(:runtime, runtime)
        end
    end
  end

  def call(event, _opts), do: Map.put(event, :status, :error) |> Map.put(:error, :invalid_action_shape)

  defp resolve_transition(spec, event_name) do
    transitions = Map.get(spec, :transitions) || %{}

    Map.get(transitions, event_name) ||
      Map.get(transitions, to_string(event_name)) ||
      Map.get(transitions, normalize_event_key(event_name))
  end

  defp resolve_action(nil), do: nil

  defp resolve_action(%{action: action}), do: normalize_action(action)
  defp resolve_action(%{"action" => action}), do: normalize_action(action)
  defp resolve_action(_), do: nil

  defp normalize_action(%{type: :capability, handle: handle}), do: {:capability, handle}
  defp normalize_action(%{type: "capability", handle: handle}), do: {:capability, handle}
  defp normalize_action(%{"type" => "capability", "handle" => handle}), do: {:capability, handle}
  defp normalize_action(%{"type" => :capability, "handle" => handle}), do: {:capability, handle}
  defp normalize_action(%{type: :save_step} = action), do: {:save_step, Map.get(action, :key)}
  defp normalize_action(%{type: "save_step"} = action), do: {:save_step, Map.get(action, :key)}
  defp normalize_action(%{"type" => "save_step"} = action), do: {:save_step, Map.get(action, "key")}
  defp normalize_action(%{"type" => :save_step} = action), do: {:save_step, Map.get(action, "key")}
  defp normalize_action(_), do: nil

  defp normalize_event_key(event) when is_atom(event), do: event
  defp normalize_event_key(event) when is_binary(event) do
    try do
      String.to_existing_atom(event)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_event_key(_), do: nil

  defp maybe_put_action_result(runtime, %{result: result}), do: Map.put(runtime, :action_result, result)
  defp maybe_put_action_result(runtime, _), do: runtime

  defp artifacts_from(%{artifacts: %{} = artifacts}), do: artifacts
  defp artifacts_from(%{"artifacts" => %{} = artifacts}), do: artifacts
  defp artifacts_from(_), do: %{}

  defp apply_save_step(runtime, step_key, payload) do
    context = Map.get(runtime, :context, %{}) || %{}
    normalized_payload = normalize_save_payload(payload)
    cleaned_payload = reject_nil_values(normalized_payload)

    case normalize_step_key(step_key) do
      nil ->
        Map.merge(context, cleaned_payload)

      key ->
        steps = Map.get(context, "steps") || Map.get(context, :steps) || %{}
        steps = Map.put(steps, key, cleaned_payload)

        context
        |> Map.put("steps", steps)
        |> Map.put(key, cleaned_payload)
        |> Map.merge(cleaned_payload)
    end
  end

  defp normalize_save_payload(%{"discovery" => %{} = discovery_payload}), do: discovery_payload
  defp normalize_save_payload(%{discovery: %{} = discovery_payload}), do: discovery_payload
  defp normalize_save_payload(payload) when is_map(payload), do: payload
  defp normalize_save_payload(_), do: %{}

  defp normalize_step_key(key) when is_binary(key) and byte_size(key) > 0, do: key
  defp normalize_step_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_step_key(_), do: nil

  defp reject_nil_values(payload) do
    payload
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
