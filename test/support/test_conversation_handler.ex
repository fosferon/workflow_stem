defmodule WorkflowStem.TestConversationHandler do
  @moduledoc """
  Test double for WorkflowStem.Adapters.ConversationHandler.

  Demonstrates the generalized contract: the handler constructs its own
  domain vocabulary. No consumer-specific field names are hardcoded in
  the framework.
  """

  @behaviour WorkflowStem.Adapters.ConversationHandler

  @impl true
  def handle_conversation(event, runtime, trigger, payload, action_config) do
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

    # Read completion signals from the action config (consumer-defined)
    completion_signal =
      Map.get(action_config, :completion_signal) ||
        Map.get(action_config, "completion_signal")

    completion_event =
      Map.get(action_config, :completion_event) ||
        Map.get(action_config, "completion_event")

    # Build a generic history entry (consumer vocabulary)
    history =
      (Map.get(context, "conversation_history", []) || []) ++
        [%{"role" => "assistant", "content" => response}]

    updated_context =
      context
      |> Map.put("conversation_response", response)
      |> Map.put("conversation_history", history)

    updated_context =
      if completion_signal do
        updated_context
        |> Map.put("conversation_complete", true)
        |> then(fn ctx ->
          if completion_event, do: Map.put(ctx, "next_event", completion_event), else: ctx
        end)
      else
        updated_context
      end

    updated_runtime = Map.put(runtime, :context, updated_context)
    %{event | runtime: updated_runtime}
  end
end
