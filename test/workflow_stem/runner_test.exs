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

  # GC-6958: the engine's init (the first step's entry action) runs in the
  # runner, not in start/3's caller; its outcome arrives as events.
  defmodule ScriptedEngine do
    @moduledoc false
    # init/2 does what the test put in the application env under
    # :scripted_init: block until released, wait, fail, or raise.

    def init(spec, ctx) do
      runtime = %{
        spec: spec,
        current_state: spec.initial_state,
        execution_id: ctx.execution_id,
        context: %{}
      }

      case Application.get_env(:workflow_stem, :scripted_init) do
        {:block, owner} ->
          send(owner, {:init_running, self()})

          receive do
            :release -> {:ok, runtime}
          end

        {:wait, cfg} ->
          {:wait, runtime, cfg}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "init blew up"
      end
    end

    def handle_event(runtime, _event, _payload), do: {:ok, %{runtime | current_state: :done}}
    def get_state(_runtime), do: %{available_events: [:next]}
  end

  defmodule PidControl do
    @moduledoc false
    def register_execution(_execution_id, pid, _speed) do
      send(Process.whereis(WorkflowStem.RunnerTest.Owner), {:runner, pid})
      :ok
    end

    def peek(_execution_id), do: nil
    def get_pause_report(_execution_id), do: nil
  end

  defp scripted_spec do
    %{
      profile: :stepwise,
      initial_state: :first,
      steps: [:first, :done],
      states: %{
        first: %{step_number: 0, ui: %{key: :first, assigns: %{type: "prompt"}}},
        done: %{step_number: 1, ui: %{key: :done, assigns: %{type: "done"}}}
      },
      transitions: %{}
    }
  end

  defp start_scripted(script) do
    Application.put_env(:workflow_stem, :scripted_init, script)
    on_exit(fn -> Application.delete_env(:workflow_stem, :scripted_init) end)
    exec_id = "runner-init-#{System.unique_integer([:positive])}"

    result =
      Runner.start(scripted_spec(), %{},
        tenant_id: "t1",
        execution_id: exec_id,
        engine: ScriptedEngine,
        event_sink: MemorySink,
        control_store: PidControl,
        checkpoint_store: NoopCheckpoint
      )

    {result, exec_id}
  end

  test "start returns while the first step is still running, and the run goes on" do
    {result, exec_id} = start_scripted({:block, self()})

    assert result == {:ok, exec_id}
    assert_receive {:event, %{kind: :started}}, 1_000
    assert_receive {:init_running, runner}, 1_000
    refute_received {:event, %{kind: :step_started}}

    send(runner, :release)
    assert_receive {:event, %{kind: :step_started, payload: %{step_id: "first"}}}, 1_000
    assert_receive {:event, %{kind: :completed}}, 1_000
  end

  test "a first step that waits is checkpointed and resumes" do
    cfg = %{"kind" => "checkpoint", "display" => "Look", "actions" => ["approve"]}
    {{:ok, _}, _exec_id} = start_scripted({:wait, cfg})

    assert_receive {:runner, runner}, 1_000
    assert_receive {:event, %{kind: :step_started, payload: %{step_id: "first"}}}, 1_000
    assert_receive {:event, %{kind: :checkpoint, payload: %{display: "Look"}}}, 1_000

    send(runner, {:resume, %{}})
    assert_receive {:event, %{kind: :completed}}, 1_000
  end

  test "an init error arrives as a failed step and a pause, not as start's return" do
    {result, exec_id} = start_scripted({:error, :bad_spec})

    assert result == {:ok, exec_id}

    assert_receive {:event,
                    %{kind: :step_failed, payload: %{step_id: "first", reason: :bad_spec}}},
                   1_000

    assert_receive {:event, %{kind: :paused, payload: %{report: %{reason: :bad_spec}}}}, 1_000
  end

  test "an init that raises fails the run and leaves the caller running" do
    {{:ok, _}, _exec_id} = start_scripted(:raise)

    assert_receive {:event,
                    %{kind: :step_failed, payload: %{reason: {:init_raised, "init blew up"}}}},
                   1_000

    assert_receive {:event, %{kind: :paused}}, 1_000
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
