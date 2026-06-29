defmodule WorkflowStem.RunnerTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.Runner

  defmodule MemorySink do
    @behaviour WorkflowStem.Adapters.EventSink

    def append_event(_tenant_id, event) do
      Agent.get_and_update(__MODULE__, fn events ->
        seq = length(events) + 1
        event = Map.put(event, :seq, seq)
        {{:ok, event}, events ++ [event]}
      end)
    end

    def publish_event(event) do
      send(Process.whereis(WorkflowStem.RunnerTest.Owner), {:event, event})
      :ok
    end

    def replay(_tenant_id, execution_id, opts) do
      since_seq = Keyword.get(opts, :since_seq, 0)

      events =
        Agent.get(__MODULE__, fn events ->
          Enum.filter(events, &(&1.execution_id == execution_id and (&1.seq || 0) > since_seq))
        end)

      {:ok, events}
    end
  end

  defmodule NoopControl do
    @behaviour WorkflowStem.Adapters.ControlStore

    def register_execution(_execution_id, _pid, _speed), do: :ok
    def peek(_execution_id), do: nil
    def get_pause_report(_execution_id), do: nil
  end

  defmodule NoopCheckpoint do
    @behaviour WorkflowStem.Adapters.CheckpointStore

    def checkpoint(_runtime, _wait_cfg), do: :ok
    def restore(_execution_id, _spec), do: {:error, :not_implemented}
    def mark_status(_execution_id, _status), do: :ok
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: MemorySink)
    Process.register(self(), WorkflowStem.RunnerTest.Owner)

    on_exit(fn ->
      if Process.whereis(MemorySink), do: Agent.stop(MemorySink)

      if Process.whereis(WorkflowStem.RunnerTest.Owner),
        do: Process.unregister(WorkflowStem.RunnerTest.Owner)
    end)

    :ok
  end

  test "emits durable ordered events and supports replay from a sequence" do
    spec = %{
      profile: :stepwise,
      initial_state: :first,
      steps: [:first, :done],
      states: %{
        first: %{step_number: 0, ui: %{key: :first, assigns: %{type: "prompt"}}},
        done: %{step_number: 1, ui: %{key: :done, assigns: %{type: "done"}}}
      },
      transitions: %{}
    }

    exec_id = "runner-test-#{System.unique_integer([:positive])}"

    assert {:ok, ^exec_id} =
             Runner.start(spec, %{},
               tenant_id: "t1",
               execution_id: exec_id,
               event_sink: MemorySink,
               control_store: NoopControl,
               checkpoint_store: NoopCheckpoint
             )

    assert_receive {:event, %{kind: :started, seq: 1}}, 1_000
    assert_receive {:event, %{kind: :step_started, payload: %{step_id: "first"}}}, 1_000
    assert_receive {:event, %{kind: :completed}}, 1_000

    assert {:ok, events} = Runner.replay(MemorySink, "t1", exec_id, since_seq: 1)
    assert Enum.all?(events, &(&1.seq > 1))
    assert Enum.map(events, & &1.kind) |> Enum.member?(:completed)
  end
end
