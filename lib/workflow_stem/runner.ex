defmodule WorkflowStem.Runner do
  @moduledoc """
  Host-parameterized runner for Stepwise executions.

  The runner owns the FSM walk, wait/resume loop, control checks, checkpoint
  hooks, and canonical event emission. Hosts provide persistence, live
  publication, and control-state implementations through adapter modules.

  `start/3` returns as soon as the runner process has offered itself to the
  control store and emitted `:started`; the engine's `init/2`, which runs
  the first step's entry action, runs in that process, not in the caller.
  Everything that happens from the first step on, an init failure
  included, arrives as events.
  """

  require Logger

  alias WorkflowStem.Engines.StepwiseEngine, as: Engine
  alias WorkflowStem.EventLog
  alias WorkflowStem.Projection

  # How long start/3 waits for the runner to report started.
  @runner_start_timeout 1_000

  @type opts :: [
          tenant_id: String.t(),
          execution_id: String.t(),
          workflow_name: String.t(),
          speed: pos_integer(),
          control_store: module(),
          checkpoint_store: module(),
          event_sink: module(),
          engine: module(),
          next_event: (map() -> atom()),
          metadata: map()
        ]

  @doc """
  Starts a run of `spec` and returns `{:ok, execution_id}` once its runner
  process has offered itself to the control store (a store that fails is
  logged, not fatal) and emitted `:started`.

  The runner then calls the engine's `init/2` (the first step's entry
  action) itself, so a long first step never blocks the caller. Its outcome
  arrives as events: an initial state that is ready runs on; one that waits
  is checkpointed and emits its wait (`:checkpoint` or `:paused`) like any
  later step; an init error, the entry action's or the spec's, marks the run
  failed and emits `:step_failed` and `:paused` with the reason, as does an
  init that raises (`{:init_raised, message}`), throws (`{:init_threw,
  value}`), exits (`{:init_exited, reason}`) or returns an unexpected value
  (`{:unexpected_init_result, value}`). A runner that does not report
  started within a second is stopped, and the call returns `{:error,
  :runner_start_timeout}`.
  """
  @spec start(map(), map(), opts()) :: {:ok, String.t()} | {:error, term()}
  def start(spec, inputs \\ %{}, opts \\ []) when is_map(spec) and is_map(inputs) do
    execution_id = Keyword.get_lazy(opts, :execution_id, &uuid4/0)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    engine = Keyword.get(opts, :engine, Engine)

    init_context = %{tenant_id: tenant_id, execution_id: execution_id, initial_context: inputs}

    start_runner_task(
      {spec, init_context},
      opts_for(opts, execution_id, tenant_id, engine),
      :init
    )
  end

  @spec start_from_runtime(map(), opts()) :: {:ok, String.t()} | {:error, term()}
  def start_from_runtime(runtime, opts \\ []) when is_map(runtime) do
    execution_id = Map.get(runtime, :execution_id) || Map.get(runtime, "execution_id")

    tenant_id =
      Map.get(runtime, :tenant_id) || Map.get(runtime, "tenant_id") ||
        Keyword.get(opts, :tenant_id, "default")

    engine = Keyword.get(opts, :engine, Engine)
    start_runner_task(runtime, opts_for(opts, execution_id, tenant_id, engine), :restored)
  end

  @spec replay(module() | nil, String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def replay(event_sink, tenant_id, execution_id, opts \\ []) do
    EventLog.replay(event_sink, tenant_id, execution_id, opts)
  end

  defp opts_for(opts, execution_id, tenant_id, engine) do
    %{
      execution_id: execution_id,
      tenant_id: tenant_id,
      workflow_name: Keyword.get(opts, :workflow_name),
      speed: Keyword.get(opts, :speed, 3),
      control_store: Keyword.get(opts, :control_store),
      checkpoint_store: Keyword.get(opts, :checkpoint_store),
      event_sink: Keyword.get(opts, :event_sink),
      engine: engine,
      next_event: Keyword.get(opts, :next_event, fn _runtime -> :next end),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp start_runner_task(runtime_or_init, opts, init_status) do
    parent = self()
    execution_id = opts.execution_id
    # Each start's report carries its own reference: a report that arrives
    # after its start gave up can answer no other start, the same run id
    # started again included.
    ref = make_ref()

    {:ok, task} =
      Task.start_link(fn ->
        register_execution(opts)
        emit(opts, if(init_status == :restored, do: :restored, else: :started), %{})
        send(parent, {:runner_started, ref, opts.execution_id})

        case init_status do
          :init ->
            {spec, init_context} = runtime_or_init
            init_in_runner(spec, init_context, opts)

          :restored ->
            loop(runtime_or_init, opts, %{})
        end
      end)

    # Only this start's own report counts (its ref).
    receive do
      {:runner_started, ^ref, ^execution_id} ->
        {:ok, execution_id}
    after
      @runner_start_timeout ->
        # A runner that never reported started is stopped, not left running
        # behind an error the caller sees, and a report it sent at the last
        # moment is taken out of the caller's mailbox.
        Process.unlink(task)
        Process.exit(task, :kill)

        receive do
          {:runner_started, ^ref, ^execution_id} -> :ok
        after
          0 -> :ok
        end

        {:error, :runner_start_timeout}
    end
  end

  # The engine's init runs the initial state's entry action (the first step),
  # here in the runner rather than in start/3's caller.
  defp init_in_runner(spec, init_context, opts) do
    case safe_init(opts.engine, spec, init_context) do
      {:ok, runtime} ->
        emit_state_events(opts, runtime)
        loop(runtime, opts, %{})

      {:wait, runtime, wait_cfg} ->
        emit_step_started(opts, step_for_runtime(runtime), runtime)
        wait_at(runtime, opts, wait_cfg)

      {:error, {:initial_entry_action_failed, reason, runtime}} ->
        handle_init_error(opts, runtime, reason)

      {:error, reason} ->
        handle_init_error(opts, spec_runtime(spec), reason)

      other ->
        handle_init_error(opts, spec_runtime(spec), {:unexpected_init_result, other})
    end
  end

  # Any crash in init (an exception, a throw, an exit, e.g. from a
  # capability's GenServer.call) is a failed first step, reported as events;
  # it never reaches the caller through the link.
  defp safe_init(engine, spec, init_context) do
    engine.init(spec, init_context)
  rescue
    error -> {:error, {:init_raised, Exception.message(error)}}
  catch
    :throw, value -> {:error, {:init_threw, value}}
    :exit, reason -> {:error, {:init_exited, reason}}
  end

  # A runtime-shaped map for reporting a spec that did not initialise: its
  # initial state, so the failure names the step it could not enter.
  defp spec_runtime(spec) do
    state = Map.get(spec, :initial_state) || Map.get(spec, "initial_state")
    %{current_state: state, spec: spec, context: %{}}
  end

  defp wait_at(runtime, opts, wait_cfg) do
    checkpoint(opts, runtime, wait_cfg)
    emit_wait(opts, wait_cfg)

    case wait_for_resume() do
      {:resume, resume_payload} -> loop(runtime, opts, resume_payload)
      :abort -> mark_status(opts, "aborted") && emit(opts, :aborted, %{})
    end
  end

  # The failed step's id; "unknown" when the runtime names no state.
  defp step_id(%{id: id}, _runtime) when is_binary(id) and id != "", do: id

  defp step_id(_step, runtime) do
    case Map.get(runtime, :current_state) do
      nil -> "unknown"
      state -> to_string(state)
    end
  end

  defp handle_init_error(opts, runtime, reason) do
    step = step_for_runtime(runtime)
    step_id = step_id(step, runtime)

    if step.id, do: emit_step_started(opts, step, runtime)

    mark_status(opts, "failed")
    emit(opts, :step_failed, %{step_id: step_id, reason: reason})
    emit_pause(opts, %{reason: reason})
  end

  defp loop(runtime, opts, resume_payload) do
    case peek_control(opts) do
      %{signal: :abort} ->
        mark_status(opts, "aborted")
        emit(opts, :aborted, %{})

      _ ->
        if terminal?(runtime, opts) do
          mark_status(opts, "completed")
          emit(opts, :completed, %{})
        else
          advance_once(runtime, opts, resume_payload || %{})
        end
    end
  end

  defp advance_once(runtime, opts, payload) do
    event = opts.next_event.(runtime)
    old_state = runtime.current_state

    case opts.engine.handle_event(runtime, event, payload) do
      {:ok, new_runtime} ->
        if new_runtime.current_state != old_state do
          emit_state_events(opts, new_runtime)
        end

        loop(new_runtime, opts, %{})

      {:wait, new_runtime, wait_cfg} ->
        if new_runtime.current_state != old_state do
          emit_step_started(opts, step_for_runtime(new_runtime), new_runtime)
        end

        wait_at(new_runtime, opts, wait_cfg)

      {:error, reason, failed_runtime} ->
        step = step_for_runtime(failed_runtime)
        step_id = step_id(step, failed_runtime)
        mark_status(opts, "failed")
        emit(opts, :step_failed, %{step_id: step_id, reason: reason})
        emit_pause(opts, %{reason: reason})
    end
  end

  defp emit_state_events(opts, runtime) do
    step = step_for_runtime(runtime)

    if step.id do
      emit_step_started(opts, step, runtime)
      emit_step_completed(opts, step, runtime)
    end
  end

  defp emit_step_started(_opts, %{id: nil}, _runtime), do: :ok

  defp emit_step_started(opts, step, runtime) do
    emit(opts, :step_started, %{
      step_id: step.id,
      type: step.type,
      index: step.index,
      total: total_steps(runtime)
    })
  end

  defp emit_step_completed(opts, step, runtime) do
    step_data = get_in(runtime.context || %{}, ["steps", step.id]) || %{}

    emit(opts, :step_completed, %{
      step_id: step.id,
      output: Map.get(step_data, "output"),
      tokens: Map.get(step_data, "tokens", %{}),
      metadata: Map.drop(step_data, ["output", "tokens"])
    })
  end

  defp emit_wait(opts, %{"kind" => "checkpoint"} = cfg),
    do: emit(opts, :checkpoint, normalize_wait_cfg(cfg))

  defp emit_wait(opts, %{kind: :checkpoint} = cfg),
    do: emit(opts, :checkpoint, normalize_wait_cfg(cfg))

  defp emit_wait(opts, cfg), do: emit_pause(opts, cfg)

  defp emit_pause(opts, default) do
    # A store that has no report, or fails to give one, leaves the default.
    report =
      case opts.control_store do
        mod when is_atom(mod) -> safe_call(fn -> mod.get_pause_report(opts.execution_id) end)
        _ -> nil
      end

    emit(opts, :paused, %{report: if(is_map(report), do: report, else: default)})
  end

  defp emit(opts, kind, payload) do
    event = %{
      execution_id: opts.execution_id,
      kind: kind,
      payload: payload,
      metadata:
        opts.metadata
        |> Map.put_new(:workflow_name, opts.workflow_name)
        |> Map.put_new(:tenant_id, opts.tenant_id)
    }

    # A sink that fails (raises, throws or exits, or an append that returns
    # an error) is logged, like every other adapter call; it does not crash the run, nor
    # its caller through the link. Once per run: a sink that stays down does
    # not log every event.
    if Process.get(:workflow_stem_sink_failed) do
      _ = quiet_call(fn -> EventLog.emit(opts.event_sink, opts.tenant_id, event) end)
    else
      case try_call(fn -> EventLog.emit(opts.event_sink, opts.tenant_id, event) end) do
        failure when elem(failure, 0) in [:failed, :error] ->
          why =
            if elem(failure, 0) == :failed, do: elem(failure, 1), else: inspect(elem(failure, 1))

          Process.put(:workflow_stem_sink_failed, true)

          Logger.warning(
            "[WorkflowStem.Runner] event sink failed (#{why}); further sink failures " <>
              "in this run are not logged"
          )

        _emitted ->
          :ok
      end
    end

    :ok
  end

  defp checkpoint(opts, runtime, wait_cfg) do
    case opts.checkpoint_store do
      mod when is_atom(mod) -> safe_call(fn -> mod.checkpoint(runtime, wait_cfg) end)
      _ -> :ok
    end
  end

  defp mark_status(opts, status) do
    case opts.checkpoint_store do
      mod when is_atom(mod) -> safe_call(fn -> mod.mark_status(opts.execution_id, status) end)
      _ -> :ok
    end
  end

  defp register_execution(opts) do
    case opts.control_store do
      mod when is_atom(mod) ->
        safe_call(fn -> mod.register_execution(opts.execution_id, self(), opts.speed) end)

      _ ->
        :ok
    end
  end

  defp peek_control(opts) do
    case opts.control_store do
      mod when is_atom(mod) -> safe_call(fn -> mod.peek(opts.execution_id) end)
      _ -> nil
    end
  end

  defp wait_for_resume do
    receive do
      {:resume, payload} when is_map(payload) -> {:resume, payload}
      {:control, :abort} -> :abort
      {:control, _other} -> wait_for_resume()
    end
  end

  defp terminal?(runtime, opts) do
    step = step_for_runtime(runtime)

    cond do
      step.type in [:done, "done"] ->
        true

      true ->
        case opts.engine.get_state(runtime) do
          %Projection{available_events: []} -> true
          %{available_events: []} -> true
          _ -> false
        end
    end
  end

  defp step_for_runtime(runtime) do
    state = Map.get(runtime, :current_state)
    state_map = get_in(runtime, [:spec, :states, state]) || %{}
    assigns = get_in(state_map, [:ui, :assigns]) || %{}

    %{
      id: if(is_nil(state), do: nil, else: to_string(state)),
      type: Map.get(assigns, :type) || Map.get(assigns, "type"),
      index: Map.get(state_map, :step_number) || Map.get(state_map, "step_number")
    }
  end

  defp total_steps(runtime) do
    case get_in(runtime, [:spec, :steps]) do
      steps when is_list(steps) -> length(steps)
      _ -> map_size(get_in(runtime, [:spec, :states]) || %{})
    end
  end

  defp normalize_wait_cfg(cfg) do
    %{
      display: Map.get(cfg, "display") || Map.get(cfg, :display),
      actions: Map.get(cfg, "actions") || Map.get(cfg, :actions, [])
    }
  end

  # Every adapter call: a raise, a throw or an exit is logged and the run
  # goes on.
  defp safe_call(fun) do
    case try_call(fun) do
      {:failed, why} ->
        Logger.warning("[WorkflowStem.Runner] adapter call failed: #{why}")
        :ok

      result ->
        result
    end
  end

  defp quiet_call(fun) do
    case try_call(fun) do
      {:failed, _why} -> :ok
      result -> result
    end
  end

  defp try_call(fun) do
    fun.()
  rescue
    e -> {:failed, Exception.message(e)}
  catch
    :throw, value -> {:failed, "threw #{inspect(value)}"}
    :exit, reason -> {:failed, "exited #{inspect(reason)}"}
  end

  import Bitwise

  defp uuid4 do
    <<a1::32, a2::16, a3::16, a4::16, a5::48>> = :crypto.strong_rand_bytes(16)
    v = (a3 &&& 0x0FFF) ||| 0x4000
    r = (a4 &&& 0x3FFF) ||| 0x8000

    [
      Base.encode16(<<a1::32>>, case: :lower),
      Base.encode16(<<a2::16>>, case: :lower),
      Base.encode16(<<v::16>>, case: :lower),
      Base.encode16(<<r::16>>, case: :lower),
      Base.encode16(<<a5::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end
end
