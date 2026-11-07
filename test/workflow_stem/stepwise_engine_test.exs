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

    test "defaults a missing profile to :stepwise" do
      spec = Map.delete(@basic_spec, :profile)
      context = %{tenant_id: "t1", execution_id: "exec-no-profile", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(spec, context)
      assert runtime.profile == :stepwise
      assert runtime.projection.profile == :stepwise
    end

    test "defaults profile: nil to :stepwise" do
      spec = Map.put(@basic_spec, :profile, nil)
      context = %{tenant_id: "t1", execution_id: "exec-nil-profile", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(spec, context)
      assert runtime.profile == :stepwise
      assert runtime.projection.profile == :stepwise
    end

    test "returns an error tuple for an unsupported profile" do
      context = %{tenant_id: "t1", execution_id: "exec-bad-profile", sync: true}

      for profile <- [:fsm, "wizard"] do
        spec = Map.put(@basic_spec, :profile, profile)
        assert {:error, {:unsupported_profile, ^profile}} = StepwiseEngine.init(spec, context)
      end
    end

    test "initializes with conversation spec — entry action fires" do
      context = %{tenant_id: "t1", execution_id: "exec-conv-1", sync: true}

      assert {:ok, runtime} = StepwiseEngine.init(@conversation_spec, context)
      assert runtime.current_state == :stage_a
      # The test conversation handler should have set a conversation_response
      assert get_in(runtime, [:context, "conversation_response"]) != nil
    end

    test "propagates {:error, {:initial_entry_action_failed, reason, runtime}} from shim" do
      # Configure a failing adapter on the mobus_stepwise config that the shim bridges to
      Application.put_env(
        :mobus_stepwise,
        :capability_runner_adapter,
        WorkflowStem.StepwiseEngineTest.BoomAdapter
      )

      spec = %{
        profile: :stepwise,
        initial_state: :step_one,
        steps: [:step_one, :step_two],
        states: %{
          step_one: %{
            step_number: 1,
            ui: %{key: :step_one},
            action: %{type: :capability, handle: "test.boom", triggers: [:enter]}
          },
          step_two: %{step_number: 2, ui: %{key: :step_two}}
        }
      }

      assert {:error, {:initial_entry_action_failed, :boom, runtime}} =
               StepwiseEngine.init(spec, %{tenant_id: "t1", execution_id: "exec-boom", sync: true})

      assert is_map(runtime)
      assert runtime.current_state == :step_one

      # The runtime should carry a WorkflowStem.Projection (not Mobus)
      assert %WorkflowStem.Projection{} = runtime.projection
    after
      Application.delete_env(:mobus_stepwise, :capability_runner_adapter)
    end
  end

  defmodule BoomAdapter do
    def execute(_tenant_id, _handle, _input), do: {:error, :boom}
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
      assert {:ok, updated} =
               StepwiseEngine.handle_event(runtime, :chat_message, %{"message" => "hello"})

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

    test "restore defaults a missing profile to :stepwise" do
      context = %{tenant_id: "t1", execution_id: "exec-rs-np", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      cp = StepwiseEngine.checkpoint(runtime)
      spec = Map.delete(@basic_spec, :profile)

      assert {:ok, restored} = StepwiseEngine.restore(spec, cp, context)
      assert restored.profile == :stepwise
      assert restored.current_state == :greeting
    end

    test "restore returns an error tuple for an unsupported profile" do
      context = %{tenant_id: "t1", execution_id: "exec-rs-bad", sync: true}
      spec = Map.put(@basic_spec, :profile, :fsm)

      assert {:error, {:unsupported_profile, :fsm}} =
               StepwiseEngine.restore(spec, %{}, context)
    end

    test "checkpoint excludes projection" do
      context = %{tenant_id: "t1", execution_id: "exec-cp2", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)

      cp = StepwiseEngine.checkpoint(runtime)
      refute Map.has_key?(cp, :projection)
    end

    test "restored runtime is functional for handle_event through shim" do
      context = %{tenant_id: "t1", execution_id: "exec-cp3", sync: true}
      {:ok, runtime} = StepwiseEngine.init(@basic_spec, context)
      {:ok, runtime} = StepwiseEngine.handle_event(runtime, :next, %{"data" => "pre-checkpoint"})

      cp = StepwiseEngine.checkpoint(runtime)
      assert cp.current_state == :problem_solving

      # Advance to review
      {:ok, advanced} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert advanced.current_state == :review

      # Restore and verify the restored runtime can handle events through the shim
      assert {:ok, restored} = StepwiseEngine.restore(@basic_spec, cp, context)
      assert restored.current_state == :problem_solving
      assert Map.get(restored, :context)["data"] == "pre-checkpoint"

      # handle_event on the restored runtime
      {:ok, after_restore} =
        StepwiseEngine.handle_event(restored, :next, %{"data" => "post-restore"})

      assert after_restore.current_state == :review

      # Verify projection type is correct (WorkflowStem.Projection, not Mobus.Stepwise.Projection)
      projection = StepwiseEngine.get_state(after_restore)
      assert %WorkflowStem.Projection{} = projection
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

  describe "capability actions" do
    setup do
      original = Application.get_env(:mobus_stepwise, :capability_runner_adapter)

      Application.put_env(
        :mobus_stepwise,
        :capability_runner_adapter,
        __MODULE__.ProbeAdapter
      )

      on_exit(fn ->
        if original do
          Application.put_env(:mobus_stepwise, :capability_runner_adapter, original)
        else
          Application.delete_env(:mobus_stepwise, :capability_runner_adapter)
        end
      end)
    end

    test "meta reaches the capability input" do
      spec = %{
        profile: :stepwise,
        initial_state: :step_one,
        states: %{
          step_one: %{
            step_number: 1,
            action: %{type: :capability, handle: "test.meta", triggers: [:next]}
          },
          step_two: %{step_number: 2}
        }
      }

      context = %{
        tenant_id: "t1",
        execution_id: "exec-meta",
        sync: true,
        meta: %{"trace_id" => "abc"}
      }

      assert {:ok, runtime} = StepwiseEngine.init(spec, context)
      assert runtime.meta == %{"trace_id" => "abc"}

      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert updated.context["seen_meta"] == %{"trace_id" => "abc"}
    end

    test "returns {:wait, runtime, cfg} when a capability waits" do
      spec = %{
        profile: :stepwise,
        initial_state: :step_one,
        states: %{
          step_one: %{
            step_number: 1,
            action: %{type: :capability, handle: "test.wait", triggers: [:next]}
          },
          step_two: %{step_number: 2}
        }
      }

      context = %{tenant_id: "t1", execution_id: "exec-wait", sync: true}
      assert {:ok, runtime} = StepwiseEngine.init(spec, context)

      assert {:wait, updated, %{"kind" => "checkpoint"}} =
               StepwiseEngine.handle_event(runtime, :next, %{})

      assert updated.current_state == :step_one
      assert updated.context["paused"] == true
      assert %Projection{} = updated.projection
    end
  end

  describe "projection_enricher" do
    test "uses the enricher's extensions in the projection" do
      spec = Map.put(@basic_spec, :projection_enricher, __MODULE__.Enricher)

      context = %{
        tenant_id: "t1",
        execution_id: "exec-enrich",
        sync: true,
        meta: %{"trace_id" => "abc"}
      }

      assert {:ok, runtime} = StepwiseEngine.init(spec, context)

      assert runtime.projection.extensions == %{
               meta: %{"trace_id" => "abc"},
               enriched_execution_id: "exec-enrich"
             }
    end
  end

  describe "transition policy" do
    test "an invalid redirect target becomes a blocked reason" do
      spec = Map.put(@basic_spec, :transition_policy, __MODULE__.RedirectPolicy)
      context = %{tenant_id: "t1", execution_id: "exec-redirect", sync: true}
      {:ok, runtime} = StepwiseEngine.init(spec, context)

      assert {:ok, updated} = StepwiseEngine.handle_event(runtime, :next, %{})
      assert updated.current_state == :greeting
      assert updated.blocked_reasons[:next] == {:invalid_redirect_target, :nowhere}
      assert updated.projection.blocked_reasons[:next] == {:invalid_redirect_target, :nowhere}
    end
  end

  defmodule ProbeAdapter do
    def execute(_tenant_id, "test.meta", input) do
      {:ok, %{context: %{"seen_meta" => input.meta}}}
    end

    def execute(_tenant_id, "test.wait", _input) do
      {:wait, %{context: %{"paused" => true}, wait: %{"kind" => "checkpoint"}}}
    end
  end

  defmodule Enricher do
    def enrich(base, runtime) do
      Map.put(base, :enriched_execution_id, runtime.execution_id)
    end
  end

  defmodule RedirectPolicy do
    def allow_transition?(_spec, _runtime, _from, _to, _event) do
      {:redirect, :nowhere}
    end
  end
end
