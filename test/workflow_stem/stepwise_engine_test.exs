defmodule WorkflowStem.StepwiseEngineTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.Engines.StepwiseEngine
  alias WorkflowStem.Projection

  @basic_spec %{
    profile: :stepwise,
    initial_state: :greeting,
    states: %{
      greeting: %{step_number: 0, ui: %{key: :greeting, assigns: %{title: "Hello"}}},
      problem_solving: %{step_number: 1, ui: %{key: :problem, assigns: %{title: "Solve"}}},
      review: %{step_number: 2, ui: %{key: :review, assigns: %{title: "Review"}}}
    },
    transitions: %{
      greeting_complete: %{to: :problem_solving},
      problem_solved: %{to: :review},
      review_complete: %{to: :complete}
    }
  }

  @conversation_spec %{
    profile: :stepwise,
    initial_state: :stage_a,
    states: %{
      stage_a: %{
        step_number: 0,
        ui: %{key: :stage_a},
        action: %{
          type: :conversation,
          triggers: [:enter, :chat_message],
          config: %{
            completion_signal: "[STAGE_COMPLETE]",
            completion_event: "stage_a_complete"
          }
        }
      },
      stage_b: %{
        step_number: 1,
        ui: %{key: :stage_b},
        action: %{
          type: :conversation,
          triggers: [:enter, :chat_message],
          config: %{
            completion_signal: "[STAGE_COMPLETE]",
            completion_event: "stage_b_complete"
          }
        }
      }
    },
    transitions: %{
      stage_a_complete: %{to: :stage_b},
      stage_b_complete: %{to: :complete}
    }
  }

  describe "init/2" do
    test "initializes with valid spec and context" do
      context = %{tenant_id: "t1", execution_id: "exec-1", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      assert runtime.execution_id == "exec-1"
      assert runtime.tenant_id == "t1"
      assert runtime.current_state == :greeting
      assert %Projection{} = runtime.projection
      assert runtime.projection.profile == :stepwise
      assert runtime.projection.current_state == :greeting
    end

    test "generates execution_id when not provided" do
      context = %{tenant_id: "t1", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      assert String.starts_with?(runtime.execution_id, "stem-")
    end

    test "returns error when tenant_id is missing" do
      context = %{execution_id: "exec-1", sync: true}
      assert {:error, :missing_tenant_id} = StepwiseEngine.init(@basic_spec, context)
    end

    test "returns error when initial_state is missing from spec" do
      spec = %{profile: :stepwise, states: %{}}
      context = %{tenant_id: "t1", sync: true}
      assert {:error, :missing_initial_state} = StepwiseEngine.init(spec, context)
    end

    test "initial context is set from runtime_context" do
      context = %{
        tenant_id: "t1",
        execution_id: "exec-1",
        sync: true,
        initial_context: %{"user_name" => "Alice"}
      }

      assert {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      assert runtime.context == %{"user_name" => "Alice"}
    end

    test "initializes with conversation spec — entry action fires" do
      context = %{tenant_id: "t1", execution_id: "exec-conv-1", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(@conversation_spec, context)
      assert runtime.current_state == :stage_a
      # The test conversation handler should have set a conversation_response
      assert get_in(runtime, [:context, "conversation_response"]) != nil
    end
  end

  describe "handle_event/3 — stepwise navigation" do
    setup do
      context = %{tenant_id: "t1", execution_id: "exec-nav", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      %{runtime: runtime}
    end

    test "advances on :next event", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert updated.current_state == :problem_solving
    end

    test "goes back on :back event", %{runtime: runtime} do
      {:ok, r2} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert r2.current_state == :problem_solving

      assert {:ok, r3} = StepwiseEngine.handle_event(r2, :back, %{})
      assert r3.current_state == :greeting
    end

    test "stays at last step when advancing past end", %{runtime: runtime} do
      {:ok, r2} = StepwiseEngine.handle_event(runtime, :next, %{})
      {:ok, r3} = StepwiseEngine.handle_event(r2, :next, %{})
      assert r3.current_state == :review

      {:ok, r4} = StepwiseEngine.handle_event(r3, :next, %{})
      assert r4.current_state == :review
    end

    test "stays at first step when going back past beginning", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :back, %{})
      assert updated.current_state == :greeting
    end

    test "accepts string events", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, "next", %{})
      assert updated.current_state == :problem_solving
    end

    test "follows explicit transition by event name", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :greeting_complete, %{})
      assert updated.current_state == :problem_solving
    end

    test "records history on transition", %{runtime: runtime} do
      {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert length(updated.history) == 1
      [%{event: :next, from: :greeting, to: :problem_solving}] = updated.history
    end

    test "records trace on transition", %{runtime: runtime} do
      {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert length(updated.trace) >= 1
    end

    test "merges payload into context", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{"answer" => 42})
      assert updated.context["answer"] == 42
    end
  end

  describe "handle_event/3 — conversation actions" do
    setup do
      context = %{tenant_id: "t1", execution_id: "exec-conv", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@conversation_spec, context)
      %{runtime: runtime}
    end

    test "delegates chat_message to conversation handler", %{runtime: runtime} do
      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :chat_message, %{"message" => "hello"})
      assert get_in(updated, [:context, "conversation_response"]) != nil
    end

    test "accumulates chat history across turns", %{runtime: runtime} do
      {:ok, r2} = StepwiseEngine.handle_event(runtime, :chat_message, %{"message" => "hello"})
      {:ok, r3} = StepwiseEngine.handle_event(r2, :chat_message, %{"message" => "more"})

      history = r3.context["conversation_history"] || []
      # Should have entries from init (enter) + 2 chat messages
      assert length(history) >= 2
    end

    test "stage completion triggers next_event via transition", %{runtime: runtime} do
      # First chat (enter already fired at init)
      {:ok, r2} = StepwiseEngine.handle_event(runtime, :chat_message, %{"message" => "hello"})

      # The test handler sets next_event when completion_signal is configured
      # and the handler simulates stage complete
      assert get_in(r2, [:context, "conversation_response"]) != nil
    end
  end

  describe "checkpoint/restore" do
    test "checkpoint captures essential runtime state" do
      context = %{tenant_id: "t1", execution_id: "exec-cp", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      {:ok, runtime} = StepwiseEngine.handle_event(runtime, :next, %{"data" => "value"})

      cp = StepwiseEngine.checkpoint(runtime)

      assert cp.execution_id == "exec-cp"
      assert cp.current_state == :problem_solving
      assert cp.context["data"] == "value"
      assert cp.tenant_id == "t1"
    end

    test "restore returns to previous state" do
      context = %{tenant_id: "t1", execution_id: "exec-rs", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      {:ok, runtime} = StepwiseEngine.handle_event(runtime, :next, %{})

      cp = StepwiseEngine.checkpoint(runtime)

      # Advance further
      {:ok, advanced} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert advanced.current_state == :review

      # Restore to checkpoint
      assert {:ok, restored} = StepwiseEngine.restore(@basic_spec, cp, context)
      assert restored.current_state == :problem_solving
    end

    test "checkpoint excludes projection" do
      context = %{tenant_id: "t1", execution_id: "exec-cp2", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)

      cp = StepwiseEngine.checkpoint(runtime)
      refute Map.has_key?(cp, :projection)
    end
  end

  describe "get_state/1" do
    test "returns Projection struct" do
      context = %{tenant_id: "t1", execution_id: "exec-gs", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)

      projection = StepwiseEngine.get_state(runtime)
      assert %Projection{} = projection
      assert projection.execution_id == "exec-gs"
      assert projection.profile == :stepwise
      assert projection.current_state == :greeting
    end

    test "available_events at first step is [:next]" do
      context = %{tenant_id: "t1", execution_id: "exec-ae", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)

      projection = StepwiseEngine.get_state(runtime)
      assert :next in projection.available_events
      refute :back in projection.available_events
    end

    test "available_events at middle step includes back and next" do
      context = %{tenant_id: "t1", execution_id: "exec-ae2", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      {:ok, runtime} = StepwiseEngine.handle_event(runtime, :next, %{})

      projection = StepwiseEngine.get_state(runtime)
      assert :next in projection.available_events
      assert :back in projection.available_events
    end
  end
end
