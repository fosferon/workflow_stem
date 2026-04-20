defmodule WorkflowStem.Adapters.ConversationHandler do
  @moduledoc """
  Behaviour for conversation action handling.

  Host applications implement this to connect STEM's `:conversation`
  action type to their conversation system (e.g., ConvEngine.Turn for Atrapos,
  or a PubSub pipeline for MOBuS).

  ## Callback arguments

  - `event` — the current pipeline event map (`%{spec, runtime, event, payload, ...}`)
  - `runtime` — the workflow runtime state
  - `trigger` — `:enter | :chat_message | other atom`
  - `payload` — the event payload map
  - `action_config` — the step's action config from the workflow spec

  ## Return

  Must return the (possibly updated) event map. The runtime inside the event
  will be passed to subsequent pipeline stages.
  """

  @callback handle_conversation(
              event :: map(),
              runtime :: map(),
              trigger :: atom(),
              payload :: map(),
              action_config :: map()
            ) :: map()
end
