defmodule WorkflowStem.FlowEngineTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.Engines.FlowEngine
  alias WorkflowStem.Projection

  @flow_spec %{
    profile: :flow,
    pipeline: [
      %{type: :capability, handle: "test.echo"},
      %{type: :capability, handle: "test.context_merge"}
    ]
  }

  @empty_flow_spec %{
    profile: :flow
  }

  describe "init/2" do
    test "initializes with valid flow spec" do
      context = %{tenant_id: "t1", execution_id: "flow-1", sync: true}

      assert {:ok, runtime} = FlowEngine.init(@flow_spec, context)
      assert runtime.execution_id == "flow-1"
      assert runtime.tenant_id == "t1"
      assert %Projection{} = runtime.projection
      assert runtime.projection.profile == :flow
    end

    test "initializes with empty pipeline" do
      context = %{tenant_id: "t1", execution_id: "flow-2", sync: true}

      assert {:ok, runtime} = FlowEngine.init(@empty_flow_spec, context)
      assert %Projection{} = runtime.projection
    end

    test "returns error when tenant_id is missing" do
      assert {:error, :missing_tenant_id} = FlowEngine.init(@flow_spec, %{sync: true})
    end
  end

  describe "handle_event/3" do
    setup do
      context = %{tenant_id: "t1", execution_id: "flow-ev", sync: true}
      {:ok, runtime} = FlowEngine.init(@flow_spec, context)
      %{runtime: runtime}
    end

    test "executes pipeline capabilities in sequence", %{runtime: runtime} do
      assert {:ok, updated} = FlowEngine.handle_event(runtime, :run, %{"input" => "data"})
      # First capability (test.echo) runs, then test.context_merge
      assert updated.context["echo_handle"] == "test.echo"
      assert updated.context["merged_key"] == "merged_value"
    end

    test "records trace for each step", %{runtime: runtime} do
      {:ok, updated} = FlowEngine.handle_event(runtime, :run, %{})
      flow_traces = Enum.filter(updated.trace, &(&1.kind == :flow))
      assert length(flow_traces) == 2
    end

    test "records last_event and last_result", %{runtime: runtime} do
      {:ok, updated} = FlowEngine.handle_event(runtime, :run, %{"x" => 1})
      assert updated.last_event == {:run, %{"x" => 1}}
    end

    test "handles empty pipeline spec gracefully" do
      context = %{tenant_id: "t1", execution_id: "flow-empty", sync: true}
      {:ok, runtime} = FlowEngine.init(@empty_flow_spec, context)

      assert {:ok, updated} = FlowEngine.handle_event(runtime, :run, %{"data" => "test"})
      assert updated.last_event == {:run, %{"data" => "test"}}
    end

    test "capability error stops pipeline", %{runtime: _runtime} do
      error_spec = %{
        profile: :flow,
        pipeline: [
          %{type: :capability, handle: "test.error"}
        ]
      }

      context = %{tenant_id: "t1", execution_id: "flow-err", sync: true}
      {:ok, runtime} = FlowEngine.init(error_spec, context)

      assert {:error, :test_capability_failed, updated} =
               FlowEngine.handle_event(runtime, :run, %{})

      assert updated.context != nil
    end
  end

  describe "checkpoint/restore" do
    test "roundtrip preserves flow state" do
      context = %{tenant_id: "t1", execution_id: "flow-cp", sync: true}
      {:ok, runtime} = FlowEngine.init(@flow_spec, context)
      {:ok, runtime} = FlowEngine.handle_event(runtime, :run, %{"data" => "val"})

      cp = FlowEngine.checkpoint(runtime)
      assert cp.last_event == {:run, %{"data" => "val"}}

      assert {:ok, restored} = FlowEngine.restore(@flow_spec, cp, context)
      assert restored.last_event == {:run, %{"data" => "val"}}
    end
  end

  describe "get_state/1" do
    test "returns Projection with flow profile" do
      context = %{tenant_id: "t1", execution_id: "flow-gs", sync: true}
      {:ok, runtime} = FlowEngine.init(@flow_spec, context)

      projection = FlowEngine.get_state(runtime)
      assert %Projection{} = projection
      assert projection.profile == :flow
      assert projection.available_events == []
    end
  end
end
