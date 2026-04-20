defmodule WorkflowStem.TestConversationHandler do
  @moduledoc """
  Test double for WorkflowStem.Adapters.ConversationHandler.

  Records calls and returns a predictable response. Used in engine tests
  to verify conversation action delegation without a real LLM.
  """

  @behaviour WorkflowStem.Adapters.ConversationHandler

  @impl true
  def handle_conversation(event, runtime, trigger, _payload, action_config) do
    context = Map.get(runtime, :context, %{})

    response =
      case trigger do
        :enter ->
          "Welcome to stage #{Map.get(runtime, :current_state, "unknown")}"

        :chat_message ->
          stage = Map.get(runtime, :current_state, "unknown")
          "Response for stage #{stage}"

        _ ->
          "Generic response"
      end

    # Check for completion signal in action_config
    completion_signal =
      Map.get(action_config, :completion_signal) ||
        Map.get(action_config, "completion_signal")

    completion_event =
      Map.get(action_config, :completion_event) ||
        Map.get(action_config, "completion_event")

    stage_complete = completion_signal != nil
    next_event = if stage_complete, do: completion_event, else: nil

    history =
      (Map.get(context, "chat_history", []) || []) ++
        [%{"role" => "assistant", "content" => response}]

    updated_context =
      context
      |> Map.put("agent_response", response)
      |> Map.put("chat_history", history)
      |> Map.put("thinking", false)
      |> then(fn ctx ->
        if next_event, do: Map.put(ctx, "next_event", next_event), else: ctx
      end)

    updated_runtime = Map.put(runtime, :context, updated_context)
    %{event | runtime: updated_runtime}
  end
end
