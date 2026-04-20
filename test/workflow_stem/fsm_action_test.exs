defmodule WorkflowStem.FsmActionTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.Components.FsmAction

  setup do
    original = Application.get_env(:workflow_stem, :capability_runner_adapter)
    Application.put_env(:workflow_stem, :capability_runner_adapter, WorkflowStem.TestCapabilityRunner)
    on_exit(fn -> Application.put_env(:workflow_stem, :capability_runner_adapter, original) end)
    :ok
  end

  describe "call/2 — save_step action" do
    test "saves payload under step key" do
      event = %{
        spec: %{
          transitions: %{
            save: %{from: :editing, to: :saved, action: %{type: :save_step, key: "personal_info"}}
          }
        },
        runtime: %{
          current_state: :editing,
          tenant_id: "t1",
          context: %{},
          artifacts: %{},
          trace: []
        },
        event: :save,
        payload: %{"name" => "Alice", "email" => "alice@example.com"},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result.status == :ok
      assert result.runtime.context["personal_info"] == %{"name" => "Alice", "email" => "alice@example.com"}
    end

    test "saves without key when key is nil" do
      event = %{
        spec: %{
          transitions: %{
            save: %{from: :editing, to: :saved, action: %{type: :save_step}}
          }
        },
        runtime: %{current_state: :editing, context: %{}, artifacts: %{}, trace: []},
        event: :save,
        payload: %{"name" => "Bob"},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result.runtime.context["name"] == "Bob"
    end
  end

  describe "call/2 — capability action" do
    test "executes capability and merges context" do
      event = %{
        spec: %{
          transitions: %{
            process: %{from: :idle, to: :done, action: %{type: :capability, handle: "test.echo"}}
          }
        },
        runtime: %{
          current_state: :idle,
          tenant_id: "t1",
          context: %{},
          artifacts: %{},
          trace: []
        },
        event: :process,
        payload: %{"input" => "data"},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result.status == :ok
      assert result.runtime.context["echo_handle"] == "test.echo"
    end

    test "records action in trace" do
      event = %{
        spec: %{
          transitions: %{
            go: %{from: :a, to: :b, action: %{type: :capability, handle: "test.echo"}}
          }
        },
        runtime: %{current_state: :a, tenant_id: "t1", context: %{}, artifacts: %{}, trace: []},
        event: :go,
        payload: %{},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert [%{kind: :action, handle: "test.echo"} | _] = result.runtime.trace
    end
  end

  describe "call/2 — no action" do
    test "passes through when transition has no action" do
      event = %{
        spec: %{transitions: %{go: %{from: :a, to: :b}}},
        runtime: %{current_state: :a, context: %{}, trace: []},
        event: :go,
        payload: %{},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result == event
    end

    test "passes through for unknown event" do
      event = %{
        spec: %{transitions: %{}},
        runtime: %{current_state: :a, context: %{}},
        event: :unknown,
        payload: %{},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result == event
    end
  end

  describe "call/2 — error cases" do
    test "passes through error status" do
      event = %{status: :error, error: :bad}
      assert ^event = FsmAction.call(event, %{})
    end

    test "handles capability error" do
      event = %{
        spec: %{
          transitions: %{
            fail: %{from: :a, to: :b, action: %{type: :capability, handle: "test.error"}}
          }
        },
        runtime: %{current_state: :a, tenant_id: "t1", context: %{}, artifacts: %{}, trace: []},
        event: :fail,
        payload: %{},
        status: :ok
      }

      result = FsmAction.call(event, %{})
      assert result.status == :error
    end
  end
end
