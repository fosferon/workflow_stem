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
      # The agent is linked to the test process and may already be gone.
      try do
        if Process.whereis(MemorySink), do: Agent.stop(MemorySink)
      catch
        :exit, _ -> :ok
      end

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
    # :scripted_init: block until released, wait, fail, raise, throw, exit,
    # or return something no engine should.
    @behaviour WorkflowStem.EngineBehaviour

    @impl true
    def init(spec, ctx) do
      runtime = %{
        spec: spec,
        current_state: Map.get(spec, :initial_state) || Map.get(spec, "initial_state"),
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

        :throw ->
          throw(:init_threw_this)

        :exit ->
          exit(:init_exit_reason)

        :weird ->
          :not_an_init_result
      end
    end

    @impl true
    def handle_event(runtime, _event, _payload), do: {:ok, %{runtime | current_state: :done}}
    @impl true
    def get_state(_runtime), do: %{available_events: [:next]}
    @impl true
    def checkpoint(runtime), do: Map.take(runtime, [:current_state, :context])
    @impl true
    def restore(_spec, _checkpoint, _ctx), do: {:error, :not_implemented}
  end

  defmodule SlowControl do
    @moduledoc false
    # Registers after start/3 has stopped waiting (1 s).
    def register_execution(_execution_id, _pid, _speed), do: Process.sleep(1_500)
    def peek(_execution_id), do: nil
    def get_pause_report(_execution_id), do: nil
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

  defp start_scripted(script, spec \\ scripted_spec(), control \\ PidControl) do
    Application.put_env(:workflow_stem, :scripted_init, script)
    on_exit(fn -> Application.delete_env(:workflow_stem, :scripted_init) end)

    exec_id = "runner-init-#{System.unique_integer([:positive])}"

    result =
      Runner.start(spec, %{},
        tenant_id: "t1",
        execution_id: exec_id,
        engine: ScriptedEngine,
        event_sink: MemorySink,
        control_store: control,
        checkpoint_store: NoopCheckpoint
      )

    # PidControl reports the runner before start/3 returns; a run this test
    # leaves waiting or blocked is ended with it, and the report is put back
    # for tests that want it.
    receive do
      {:runner, pid} = msg ->
        on_exit(fn -> Process.exit(pid, :kill) end)
        send(self(), msg)
    after
      0 -> :ok
    end

    {result, exec_id}
  end

  test "start returns while the first step is still running, and the run goes on" do
    {result, exec_id} = start_scripted({:block, self()})

    assert result == {:ok, exec_id}
    assert_receive {:event, %{execution_id: ^exec_id, kind: :started}}, 1_000
    assert_receive {:init_running, runner}, 1_000
    refute_received {:event, %{execution_id: ^exec_id, kind: :step_started}}

    send(runner, :release)

    assert_receive {:event,
                    %{execution_id: ^exec_id, kind: :step_started, payload: %{step_id: "first"}}},
                   1_000

    assert_receive {:event, %{execution_id: ^exec_id, kind: :completed}}, 1_000
  end

  test "a first step that waits is checkpointed and resumes" do
    cfg = %{"kind" => "checkpoint", "display" => "Look", "actions" => ["approve"]}
    {{:ok, _}, exec_id} = start_scripted({:wait, cfg})

    assert_receive {:runner, runner}, 1_000

    assert_receive {:event,
                    %{execution_id: ^exec_id, kind: :step_started, payload: %{step_id: "first"}}},
                   1_000

    assert_receive {:event,
                    %{execution_id: ^exec_id, kind: :checkpoint, payload: %{display: "Look"}}},
                   1_000

    send(runner, {:resume, %{}})
    assert_receive {:event, %{execution_id: ^exec_id, kind: :completed}}, 1_000
  end

  test "an init error arrives as a failed step and a pause, not as start's return" do
    {result, exec_id} = start_scripted({:error, :bad_spec})

    assert result == {:ok, exec_id}

    assert_receive {:event,
                    %{kind: :step_failed, payload: %{step_id: "first", reason: :bad_spec}}},
                   1_000

    assert_receive {:event,
                    %{
                      execution_id: ^exec_id,
                      kind: :paused,
                      payload: %{report: %{reason: :bad_spec}}
                    }},
                   1_000
  end

  test "an init that raises fails the run and leaves the caller running" do
    {{:ok, _}, exec_id} = start_scripted(:raise)

    assert_receive {:event,
                    %{kind: :step_failed, payload: %{reason: {:init_raised, "init blew up"}}}},
                   1_000

    assert_receive {:event, %{execution_id: ^exec_id, kind: :paused}}, 1_000
  end

  # Round 1 F1/F4: any crash or bad value from init is a failed first step;
  # the caller, linked to the runner, is not taken down.
  for {script, reason} <- [
        throw: {:init_threw, :init_threw_this},
        exit: {:init_exited, :init_exit_reason},
        weird: {:unexpected_init_result, :not_an_init_result}
      ] do
    test "an init that does #{script} fails the run and leaves the caller running" do
      {{:ok, _}, exec_id} = start_scripted(unquote(script))

      assert_receive {:event,
                      %{kind: :step_failed, payload: %{step_id: "first", reason: reason}}},
                     1_000

      assert reason == unquote(Macro.escape(reason))
      assert_receive {:event, %{execution_id: ^exec_id, kind: :paused}}, 1_000
      assert Process.alive?(self())
    end
  end

  # Round 1 F3: a spec error names the initial state by either key form,
  # and "unknown" when there is none.
  test "a spec error names the initial state, string-keyed or missing" do
    string_keyed =
      scripted_spec() |> Map.delete(:initial_state) |> Map.put("initial_state", :first)

    {{:ok, _}, exec_id} = start_scripted({:error, :bad_spec}, string_keyed)

    assert_receive {:event,
                    %{
                      execution_id: ^exec_id,
                      kind: :step_failed,
                      payload: %{step_id: "first", reason: :bad_spec}
                    }},
                   1_000

    nameless = Map.delete(scripted_spec(), :initial_state)
    {{:ok, _}, exec_id} = start_scripted({:error, :bad_spec}, nameless)

    assert_receive {:event,
                    %{
                      execution_id: ^exec_id,
                      kind: :step_failed,
                      payload: %{step_id: "unknown", reason: :bad_spec}
                    }},
                   1_000
  end

  # Round 1 F2: a runner that does not report started in time is stopped,
  # and its late report never reaches the caller.
  @tag timeout: 10_000
  test "a runner that is too slow to start is stopped and leaves no report behind" do
    {result, exec_id} = start_scripted({:block, self()}, scripted_spec(), SlowControl)

    assert result == {:error, :runner_start_timeout}
    Process.sleep(800)
    refute_received {:runner_started, ^exec_id}
    refute_received {:event, %{execution_id: ^exec_id, kind: :started}}
    refute_received {:init_running, _}
  end

  test "a stale started report from another run never answers this start" do
    send(self(), {:runner_started, make_ref(), "some-earlier-run"})
    {result, exec_id} = start_scripted({:wait, %{"kind" => "checkpoint", "display" => "x"}})

    assert result == {:ok, exec_id}
    assert_received {:runner_started, _ref, "some-earlier-run"}
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

    # The real engine: :started (seq 1) comes before the first step's events.
    assert_receive {:event, %{kind: :started, seq: 1}}, 1_000

    assert_receive {:event, %{kind: :step_started, seq: step_seq, payload: %{step_id: "first"}}},
                   1_000

    assert step_seq > 1
    assert_receive {:event, %{kind: :completed}}, 1_000

    assert {:ok, events} = Runner.replay(MemorySink, "t1", exec_id, since_seq: 1)
    assert Enum.all?(events, &(&1.seq > 1))
    assert Enum.map(events, & &1.kind) |> Enum.member?(:completed)
  end
end
