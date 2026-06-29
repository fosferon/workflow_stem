defmodule WorkflowStem.Runner do
  @moduledoc """
  Host-parameterized runner for Stepwise executions.

  The runner owns the FSM walk, wait/resume loop, control checks, checkpoint
  hooks, and canonical event emission. Hosts provide persistence, live
  publication, and control-state implementations through adapter modules.
  """

  require Logger

  alias WorkflowStem.Engines.StepwiseEngine, as: Engine
  alias WorkflowStem.EventLog
  alias WorkflowStem.Projection

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

  @spec start(map(), map(), opts()) :: {:ok, String.t()} | {:error, term()}
  def start(spec, inputs \\ %{}, opts \\ []) when is_map(spec) and is_map(inputs) do
    execution_id = Keyword.get_lazy(opts, :execution_id, &uuid4/0)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    engine = Keyword.get(opts, :engine, Engine)

    init_result =
      engine.init(spec, %{
        tenant_id: tenant_id,
        execution_id: execution_id,
        initial_context: inputs
      })

    case init_result do
      {:ok, runtime} ->
        start_runner_task(runtime, opts_for(opts, execution_id, tenant_id, engine), :ok)

      {:error, {:initial_entry_action_failed, reason, runtime}} ->
        start_runner_task(
          runtime,
          opts_for(opts, execution_id, tenant_id, engine),
          {:init_error, reason}
        )

      {:error, reason} ->
        {:error, reason}
    end
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

  defp start_runner_task(runtime, opts, init_status) do
    parent = self()

    {:ok, _task} =
      Task.start_link(fn ->
        register_execution(opts)
        emit(opts, if(init_status == :restored, do: :restored, else: :started), %{})
        send(parent, {:runner_started, opts.execution_id})

        case init_status do
          :ok ->
            emit_state_events(opts, runtime)
            loop(runtime, opts, %{})

          :restored ->
            loop(runtime, opts, %{})

          {:init_error, reason} ->
            handle_init_error(opts, runtime, reason)
        end
      end)

    receive do
      {:runner_started, execution_id} -> {:ok, execution_id}
    after
      1_000 -> {:error, :runner_start_timeout}
    end
  end

  defp handle_init_error(opts, runtime, reason) do
    step = step_for_runtime(runtime)
    step_id = step.id || to_string(Map.get(runtime, :current_state, "unknown"))

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

        checkpoint(opts, new_runtime, wait_cfg)
        emit_wait(opts, wait_cfg)

        case wait_for_resume() do
          {:resume, resume_payload} -> loop(new_runtime, opts, resume_payload)
          :abort -> mark_status(opts, "aborted") && emit(opts, :aborted, %{})
        end

      {:error, reason, failed_runtime} ->
        step = step_for_runtime(failed_runtime)
        step_id = step.id || to_string(Map.get(failed_runtime, :current_state, "unknown"))
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
    report =
      case opts.control_store do
        mod when is_atom(mod) -> safe_call(fn -> mod.get_pause_report(opts.execution_id) end)
        _ -> nil
      end

    emit(opts, :paused, %{report: report || default})
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

    _ = EventLog.emit(opts.event_sink, opts.tenant_id, event)
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

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("[WorkflowStem.Runner] adapter call failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[WorkflowStem.Runner] adapter call exited: #{inspect(reason)}")
      :ok
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
