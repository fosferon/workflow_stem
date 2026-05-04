defmodule WorkflowStem.StepwiseActionTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.Components.StepwiseAction

  describe "call/2 — capability actions" do
    setup do
      # Configure capability runner
      original = Application.get_env(:workflow_stem, :capability_runner_adapter)
      Application.put_env(:workflow_stem, :capability_runner_adapter, WorkflowStem.TestCapabilityRunner)
      on_exit(fn -> Application.put_env(:workflow_stem, :capability_runner_adapter, original) end)
      :ok
    end

    test "executes capability action when trigger matches" do
      event = %{
        spec: %{
          states: %{
            step_1: %{
              action: %{
                type: :capability,
                handle: "test.echo",
                triggers: [:next]
              }
            }
          }
        },
        runtime: %{current_state: :step_1, tenant_id: "t1", context: %{}, artifacts: %{}, trace: []},
        event: :next,
        payload: %{"input" => "hello"},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result.status == :ok
      assert result.runtime.context["echo_handle"] == "test.echo"
    end

    test "skips action when trigger doesn't match" do
      event = %{
        spec: %{
          states: %{
            step_1: %{
              action: %{
                type: :capability,
                handle: "test.echo",
                triggers: [:submit]
              }
            }
          }
        },
        runtime: %{current_state: :step_1, context: %{}, artifacts: %{}, trace: []},
        event: :next,
        payload: %{},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      # Event should pass through unchanged (no action execution)
      assert result == event
    end

    test "handles capability error gracefully" do
      event = %{
        spec: %{
          states: %{
            step_1: %{
              action: %{
                type: :capability,
                handle: "test.error",
                triggers: [:next]
              }
            }
          }
        },
        runtime: %{current_state: :step_1, tenant_id: "t1", context: %{}, artifacts: %{}, trace: []},
        event: :next,
        payload: %{},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result.status == :error
    end

    test "passes through when state has no action" do
      event = %{
        spec: %{states: %{step_1: %{}}},
        runtime: %{current_state: :step_1, context: %{}, trace: []},
        event: :next,
        payload: %{},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result == event
    end
  end

  describe "call/2 — conversation actions" do
    test "delegates to conversation handler when configured" do
      event = %{
        spec: %{
          states: %{
            stage_a: %{
              action: %{
                type: :conversation,
                triggers: [:enter, :chat_message],
                config: %{
                  completion_signal: "[DONE]",
                  completion_event: "done"
                }
              }
            }
          }
        },
        runtime: %{current_state: :stage_a, context: %{}, trace: []},
        event: :chat_message,
        payload: %{"message" => "hello"},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result.status == :ok
      assert result.runtime.context["conversation_response"] != nil
    end

    test "passes through when no conversation handler configured" do
      # Temporarily remove handler from both config slots (workflow_stem
      # bridges its config to mobus_stepwise at startup).
      original_ws = Application.get_env(:workflow_stem, :conversation_handler)
      original_ms = Application.get_env(:mobus_stepwise, :conversation_handler)
      Application.put_env(:workflow_stem, :conversation_handler, nil)
      Application.put_env(:mobus_stepwise, :conversation_handler, nil)

      event = %{
        spec: %{
          states: %{
            stage_a: %{
              action: %{type: :conversation, triggers: [:chat_message], config: %{}}
            }
          }
        },
        runtime: %{current_state: :stage_a, context: %{}, trace: []},
        event: :chat_message,
        payload: %{},
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result == event

      Application.put_env(:workflow_stem, :conversation_handler, original_ws)
      if original_ms, do: Application.put_env(:mobus_stepwise, :conversation_handler, original_ms)
    end
  end

  describe "call/2 — edge cases" do
    test "passes through error status events" do
      event = %{status: :error, error: :bad}
      assert ^event = StepwiseAction.call(event, %{})
    end

    test "handles non-map payload" do
      event = %{
        spec: %{states: %{}},
        runtime: %{current_state: :s1, context: %{}},
        event: :next,
        payload: "invalid",
        status: :ok
      }

      result = StepwiseAction.call(event, %{})
      assert result.status == :error
    end
  end
end
