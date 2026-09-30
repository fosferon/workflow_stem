defmodule WorkflowStem.Definition.Run do
  @moduledoc """
  Drives a run of a definition.

  The engine moves one step per event. This module fires the events: it
  keeps a run going until it finishes, fails, or every branch still alive is
  waiting for something outside — a person, a provider, a deadline.

      {:ok, outcome} = Run.start(definition, tenant_id: tenant, params: chosen, persist: &save/1)

  `outcome.status` is `:completed`, `:waiting` or `:failed`.
  `outcome.checkpoint` is what to store: it survives JSON, and
  `resume/3`, `timeout/3` and `continue/3` take it back.

  `:persist` is called with the outcome at the end, and with a `:running`
  snapshot every `:checkpoint_every` events on the way — so a run that is
  interrupted can be picked up with `continue/3` from its last snapshot
  rather than from the start. Every block must therefore be safe to repeat.

  The capability runner the engine calls is the host's, configured as for
  any other workflow; it hands block handles to
  `WorkflowStem.Definition.Blocks.execute/4`.
  """

  alias Mobus.Stepwise.Engine
  alias WorkflowStem.Definition
  alias WorkflowStem.Definition.Inputs

  @default_checkpoint_every 25
  @default_max_events 1_000_000

  @type outcome :: %{
          status: :running | :completed | :waiting | :failed,
          checkpoint: map(),
          context: map(),
          error: term(),
          next_deadline: DateTime.t() | nil,
          waiting: %{String.t() => map()},
          events: non_neg_integer()
        }

  @doc """
  Starts a run.

  Options: `:tenant_id` (required), `:run_id`, `:params` (the chosen dial
  values), `:context` (extra starting data, e.g. `%{"trigger" => …}`),
  `:persist`, `:checkpoint_every`, `:max_events`.
  """
  @spec start(map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def start(definition, opts) do
    with {:ok, tenant_id} <- fetch_tenant(opts),
         {:ok, definition} <- Definition.normalize(definition),
         {:ok, spec} <- Definition.compile(definition),
         {:ok, params} <- resolve_params(definition, opts),
         context = opts |> Keyword.get(:context, %{}) |> Map.put("params", params),
         {:ok, runtime} <- Engine.init(spec, runtime_context(tenant_id, opts, context)) do
      {:ok, walk(runtime, opts)}
    end
  end

  @doc """
  Resumes a waiting branch. `:token_id` names it; `:context` is what the
  outside world hands it (the form, the clicked link). `:event` defaults to
  `:resume`. The ids of the waiting branches are the keys of
  `outcome.waiting`; a block learns its own branch's id from `env.token_id`
  (what a claim link carries). Resuming a branch that is not waiting is an
  error.
  """
  @spec resume(map(), map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def resume(definition, checkpoint, opts) do
    payload =
      %{}
      |> put_present("token_id", Keyword.get(opts, :token_id))
      |> put_present("context", Keyword.get(opts, :context))

    with {:ok, runtime} <- restore(definition, checkpoint, opts),
         :ok <- waiting?(runtime, Keyword.get(opts, :token_id)) do
      {:ok, fire(runtime, Keyword.get(opts, :event, :resume), payload, opts)}
    end
  end

  # Resuming a branch that is not waiting would quietly do nothing: a link
  # clicked twice, or clicked after it lapsed, must be told so.
  defp waiting?(runtime, nil) do
    if map_size(runtime.pending_waits) > 0, do: :ok, else: {:error, :nothing_waiting}
  end

  defp waiting?(runtime, token_id) do
    if Map.has_key?(runtime.pending_waits, token_id),
      do: :ok,
      else: {:error, {:not_waiting, token_id}}
  end

  @doc "Expires the waits whose deadline has passed, then carries on."
  @spec timeout(map(), map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def timeout(definition, checkpoint, opts) do
    with {:ok, runtime} <- restore(definition, checkpoint, opts) do
      {:ok, fire(runtime, :timeout, %{}, opts)}
    end
  end

  @doc "Carries on from a snapshot: a run that was interrupted."
  @spec continue(map(), map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def continue(definition, checkpoint, opts) do
    with {:ok, runtime} <- restore(definition, checkpoint, opts) do
      {:ok, walk(runtime, opts)}
    end
  end

  defp restore(definition, checkpoint, opts) do
    with {:ok, tenant_id} <- fetch_tenant(opts),
         {:ok, spec} <- Definition.compile(definition) do
      Engine.restore(spec, checkpoint, runtime_context(tenant_id, opts, %{}))
    end
  end

  defp fire(runtime, event, payload, opts) do
    case safe_event(runtime, event, payload) do
      {:ok, runtime} -> walk(runtime, opts)
      {:error, reason, runtime} -> finish(runtime, :failed, reason, 1, opts)
    end
  end

  defp walk(runtime, opts), do: walk(runtime, 0, opts)

  defp walk(runtime, events, opts) do
    cond do
      events >= Keyword.get(opts, :max_events, @default_max_events) ->
        finish(runtime, :failed, {:max_events_exceeded, events}, events, opts)

      ready?(runtime) ->
        case safe_event(runtime, :next, %{}) do
          {:ok, runtime} ->
            events = events + 1
            snapshot_on_the_way(runtime, events, opts)
            walk(runtime, events, opts)

          {:error, reason, runtime} ->
            finish(runtime, :failed, reason, events, opts)
        end

      map_size(runtime.pending_waits) > 0 ->
        finish(runtime, :waiting, nil, events, opts)

      true ->
        finish(runtime, :completed, nil, events, opts)
    end
  end

  # A block that raises must not take the run's state with it: the run fails
  # at the state it had before the step, which is what `continue/3` resumes.
  defp safe_event(runtime, event, payload) do
    case Engine.handle_event(runtime, event, payload) do
      {:ok, runtime} -> {:ok, runtime}
      {:wait, runtime, _wait} -> {:ok, runtime}
      {:error, reason, runtime} -> {:error, reason, runtime}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}, runtime}
  catch
    kind, value -> {:error, {kind, inspect(value)}, runtime}
  end

  defp ready?(runtime),
    do: Enum.any?(runtime.active_tokens, fn {_id, token} -> token.status == :ready end)

  defp snapshot_on_the_way(runtime, events, opts) do
    every = Keyword.get(opts, :checkpoint_every, @default_checkpoint_every)

    if is_integer(every) and every > 0 and rem(events, every) == 0 do
      persist(outcome(runtime, :running, nil, events), opts)
    end
  end

  defp finish(runtime, status, error, events, opts) do
    outcome = outcome(runtime, status, error, events)
    persist(outcome, opts)
    outcome
  end

  defp outcome(runtime, status, error, events) do
    %{
      status: status,
      checkpoint: runtime |> Engine.checkpoint() |> Map.delete(:spec),
      context: runtime.context,
      error: error,
      next_deadline: next_deadline(runtime.pending_waits),
      waiting: runtime.pending_waits,
      events: events
    }
  end

  defp persist(outcome, opts) do
    case Keyword.get(opts, :persist) do
      fun when is_function(fun, 1) -> fun.(outcome)
      _ -> :ok
    end
  end

  defp next_deadline(waits) do
    waits
    |> Enum.flat_map(fn {_token_id, wait} ->
      case Map.get(wait, :deadline) do
        %DateTime{} = deadline ->
          [deadline]

        deadline when is_binary(deadline) ->
          case DateTime.from_iso8601(deadline) do
            {:ok, parsed, _offset} -> [parsed]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp resolve_params(definition, opts) do
    case Inputs.resolve(Map.get(definition, "inputs"), Keyword.get(opts, :params)) do
      {:ok, params} -> {:ok, params}
      {:error, errors} -> {:error, {:invalid_params, errors}}
    end
  end

  defp fetch_tenant(opts) do
    case Keyword.get(opts, :tenant_id) do
      nil -> {:error, :missing_tenant_id}
      tenant_id -> {:ok, tenant_id}
    end
  end

  defp runtime_context(tenant_id, opts, context) do
    %{
      tenant_id: tenant_id,
      sync: true,
      initial_context: context,
      meta: Keyword.get(opts, :meta, %{})
    }
    |> put_present(:execution_id, Keyword.get(opts, :run_id))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
