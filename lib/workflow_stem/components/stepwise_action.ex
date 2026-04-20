defmodule WorkflowStem.Components.StepwiseAction do
  @moduledoc """
  Executes declarative per-step actions for `:stepwise` workflows.

  A step action is expected to live under the current state's definition:

      states: %{
        step_1: %{action: %{type: :capability, handle: "cap.handle"}},
        ...
      }

  For now, actions are executed only on `:next` (and `"next"`) events.
  """

  alias WorkflowStem.Artifacts
  alias WorkflowStem.Capabilities

  @spec call(map(), map()) :: map()
  def call(%{status: :error} = event, _opts), do: event

  def call(%{spec: spec, runtime: runtime, event: event_name, payload: payload} = event, _opts)
      when is_map(payload) do
    do_execute_action(event, spec, runtime, event_name, payload)
  end

  def call(event, _opts),
    do: Map.put(event, :status, :error) |> Map.put(:error, :invalid_action_shape)

  @doc false
  def run_entry_action(%{spec: spec, runtime: runtime} = event) do
    do_execute_action(event, spec, runtime, :__enter__, %{})
  end

  defp do_execute_action(event, spec, runtime, event_name, payload) do
    event_key = normalize_event_key(event_name)

    case resolve_step_action(spec, Map.get(runtime, :current_state)) do
      nil ->
        event

      {:capability, handle, triggers, action_config} ->
        if trigger_match?(event_key, triggers) do
          run_capability(event, runtime, handle, event_name, payload, action_config)
        else
          event
        end

      {:conversation, triggers, action_config} ->
        if trigger_match?(event_key, triggers) do
          run_conversation(event, runtime, event_name, payload, action_config)
        else
          event
        end
    end
  end

  @conversation_handler_triggers [:enter, :__enter__, :chat_message]

  defp run_conversation(event, runtime, event_name, payload, action_config) do
    trigger = to_conversation_trigger(event_name)

    cond do
      conversation_handler() == nil ->
        # No handler configured (test env) — pass through
        event

      trigger in @conversation_handler_triggers ->
        delegate_conversation(event, runtime, trigger, payload, action_config)

      true ->
        # Completion events — merge payload into context
        merge_conversation_result(event, runtime, trigger, payload, action_config)
    end
  end

  defp conversation_handler do
    Application.get_env(:workflow_stem, :conversation_handler)
  end

  defp delegate_conversation(event, _runtime, trigger, payload, action_config) do
    handler = conversation_handler()

    if is_atom(handler) and Code.ensure_loaded?(handler) and function_exported?(handler, :handle_conversation, 5) do
      handler.handle_conversation(event, event.runtime, trigger, payload, action_config)
    else
      event
    end
  end

  defp merge_conversation_result(event, runtime, _trigger, payload, config) do
    context = Map.get(runtime, :context, %{})
    response_text = Map.get(payload, "text") || Map.get(payload, :text, "")
    stage_complete = Map.get(payload, "stage_complete") || Map.get(payload, :stage_complete, false)

    history =
      (Map.get(context, "chat_history", []) || []) ++
        [%{"role" => "assistant", "content" => response_text}]

    # Merge any mid-conversation research
    research = Map.get(payload, "research") || Map.get(payload, :research)
    context = if research, do: Map.put(context, "pre_research", research), else: context

    next_event =
      if stage_complete, do: Map.get(config, :completion_event) || Map.get(config, "completion_event")

    updated_context =
      context
      |> Map.put("agent_response", response_text)
      |> Map.put("chat_history", history)
      |> Map.put("thinking", false)
      |> then(fn ctx ->
        if next_event, do: Map.put(ctx, "next_event", next_event), else: ctx
      end)

    updated_runtime = Map.put(runtime, :context, updated_context)
    %{event | runtime: updated_runtime}
  end

  defp to_conversation_trigger(event) when event in [:enter, :__enter__, "__enter__"], do: :enter
  defp to_conversation_trigger(event) when event in [:chat_message, "chat_message"], do: :chat_message
  defp to_conversation_trigger(event) when is_atom(event), do: event
  defp to_conversation_trigger(event) when is_binary(event), do: String.to_existing_atom(event)

  defp run_capability(event, runtime, handle, event_name, payload, action_config) do
    tenant_id = Map.get(runtime, :tenant_id)

    input = %{
      event: event_name,
      payload: payload,
      current_state: Map.get(runtime, :current_state),
      context: Map.get(runtime, :context, %{}),
      artifacts: Map.get(runtime, :artifacts, %{}) || %{},
      execution_id: Map.get(runtime, :execution_id),
      action_config: action_config || %{}
    }

    case Capabilities.execute(tenant_id, handle, input) do
      {:ok, %{context: %{} = context_updates} = out} ->
        runtime =
          runtime
          |> merge_context(context_updates)
          |> Map.update(:artifacts, %{}, fn artifacts ->
            Artifacts.merge(artifacts, artifacts_from(out))
          end)
          |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: handle}] end)
          |> maybe_put_action_result(out)

        %{event | runtime: runtime}

      {:ok, other} ->
        runtime =
          runtime
          |> Map.update(:trace, [], fn trace -> trace ++ [%{kind: :action, handle: handle}] end)

        %{event | runtime: runtime} |> Map.put(:action_result, other)

      {:error, reason} ->
        runtime =
          runtime
          |> Map.update(:blocked_reasons, %{}, fn reasons ->
            Map.put(reasons, event_name, reason)
          end)

        event
        |> Map.put(:status, :error)
        |> Map.put(:error, reason)
        |> Map.put(:runtime, runtime)

      {:error, reason, extra} ->
        runtime =
          runtime
          |> merge_context(Map.get(extra, :context) || Map.get(extra, "context") || %{})
          |> Map.update(:artifacts, %{}, fn artifacts ->
            Artifacts.merge(artifacts, artifacts_from(extra))
          end)
          |> Map.update(:blocked_reasons, %{}, fn reasons ->
            Map.put(reasons, event_name, reason)
          end)

        event
        |> Map.put(:status, :error)
        |> Map.put(:error, reason)
        |> Map.put(:runtime, runtime)
    end
  end

  defp merge_context(runtime, %{} = updates) when map_size(updates) == 0, do: runtime

  defp merge_context(runtime, %{} = updates) do
    Map.update(runtime, :context, %{}, fn ctx -> Map.merge(ctx, updates) end)
  end

  defp merge_context(runtime, _), do: runtime

  defp resolve_step_action(spec, state) do
    states = Map.get(spec, :states) || %{}
    state_def = Map.get(states, state) || Map.get(states, to_string(state)) || %{}

    action = Map.get(state_def, :action) || Map.get(state_def, "action")
    normalize_action(action)
  end

  defp normalize_action(nil), do: nil

  defp normalize_action(%{type: type, handle: handle} = action)
       when type in [:capability, "capability"] do
    {:capability, handle, normalize_triggers(action), Map.get(action, :config)}
  end

  defp normalize_action(%{"type" => type, "handle" => handle} = action)
       when type in [:capability, "capability"] do
    {:capability, handle, normalize_triggers(action), Map.get(action, "config") || Map.get(action, :config)}
  end

  defp normalize_action(%{type: type} = action)
       when type in [:conversation, "conversation"] do
    {:conversation, normalize_triggers(action), Map.get(action, :config)}
  end

  defp normalize_action(%{"type" => type} = action)
       when type in [:conversation, "conversation"] do
    {:conversation, normalize_triggers(action), Map.get(action, "config") || Map.get(action, :config)}
  end

  defp normalize_action(_), do: nil

  defp normalize_triggers(action) do
    raw_triggers =
      Map.get(action, :triggers) ||
        Map.get(action, "triggers") ||
        Map.get(action, :events) ||
        Map.get(action, "events") ||
        Map.get(action, :on) ||
        Map.get(action, "on") ||
        Map.get(action, :trigger) ||
        Map.get(action, "trigger")

    triggers =
      case raw_triggers do
        nil -> default_triggers()
        list when is_list(list) -> Enum.flat_map(list, &normalize_trigger/1)
        value -> normalize_trigger(value)
      end

    triggers
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> default_triggers()
      list -> Enum.uniq(list)
    end
  end

  defp default_triggers, do: [:next, "next"]

  defp normalize_trigger(:enter), do: [:enter, :__enter__, "enter", "__enter__"]
  defp normalize_trigger("enter"), do: normalize_trigger(:enter)
  defp normalize_trigger(:__enter__), do: normalize_trigger(:enter)
  defp normalize_trigger(<<"__enter__"::binary>>), do: normalize_trigger(:enter)
  defp normalize_trigger(:next), do: [:next, "next"]
  defp normalize_trigger("next"), do: [:next, "next"]
  defp normalize_trigger(trigger) when is_atom(trigger), do: [trigger, Atom.to_string(trigger)]
  defp normalize_trigger(trigger) when is_binary(trigger), do: [trigger]
  defp normalize_trigger(_), do: []

  defp trigger_match?(nil, _triggers), do: false

  defp trigger_match?(event, triggers) do
    Enum.any?(triggers, fn trigger -> equivalent_event?(event, trigger) end)
  end

  defp equivalent_event?(a, b) when is_atom(a) and is_atom(b), do: a == b
  defp equivalent_event?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp equivalent_event?(a, b) when is_atom(a) and is_binary(b), do: Atom.to_string(a) == b
  defp equivalent_event?(a, b) when is_binary(a) and is_atom(b), do: a == Atom.to_string(b)
  defp equivalent_event?(_, _), do: false

  defp normalize_event_key(event) when is_atom(event), do: event
  defp normalize_event_key(event) when is_binary(event), do: event
  defp normalize_event_key(_), do: nil

  defp maybe_put_action_result(runtime, %{result: result}),
    do: Map.put(runtime, :action_result, result)

  defp maybe_put_action_result(runtime, _), do: runtime

  defp artifacts_from(%{artifacts: %{} = artifacts}), do: artifacts
  defp artifacts_from(%{"artifacts" => %{} = artifacts}), do: artifacts
  defp artifacts_from(_), do: %{}
end
