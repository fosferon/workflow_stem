defmodule WorkflowStem.ExecutionStore do
  @moduledoc """
  In-memory execution store for the workflow stem.

  Phase 3: this is intentionally simple and deterministic to support rapid iteration.
  Persistence is introduced later via the persistence adapter.

  Keyed by `execution_id` and stores `{tenant_id, workflow_handle, profile, runtime}`.
  """

  use GenServer

  alias WorkflowStem.Types

  @name __MODULE__

  @type entry :: %{
          required(:execution_id) => Types.execution_id(),
          required(:tenant_id) => Types.tenant_id(),
          required(:workflow_handle) => Types.workflow_handle(),
          required(:profile) => Types.profile(),
          required(:runtime) => Types.runtime()
        }

  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(@name) do
      nil ->
        case GenServer.start(__MODULE__, %{}, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, {:already_started, _pid, _info}} -> :ok
          _ -> :ok
        end

      _pid ->
        :ok
    end
  end

  @spec put(entry()) :: :ok
  def put(%{execution_id: execution_id} = entry) when is_binary(execution_id) do
    ensure_started()
    GenServer.call(@name, {:put, entry})
  end

  @spec fetch(Types.execution_id()) :: {:ok, entry()} | {:error, :not_found}
  def fetch(execution_id) when is_binary(execution_id) do
    ensure_started()
    GenServer.call(@name, {:fetch, execution_id})
  end

  @spec update(Types.execution_id(), (entry() -> {:ok, entry()} | {:error, term()})) ::
          {:ok, entry()} | {:error, term()}
  def update(execution_id, fun) when is_binary(execution_id) and is_function(fun, 1) do
    ensure_started()
    GenServer.call(@name, {:update, execution_id, fun})
  end

  @spec delete(Types.execution_id()) :: :ok
  def delete(execution_id) when is_binary(execution_id) do
    ensure_started()
    GenServer.call(@name, {:delete, execution_id})
  end

  @spec list(Types.tenant_id()) :: [entry()]
  def list(tenant_id) when is_binary(tenant_id) do
    ensure_started()
    GenServer.call(@name, {:list, tenant_id})
  end

  @impl true
  def init(state), do: {:ok, Map.put(state, :by_execution_id, %{})}

  @impl true
  def handle_call({:put, %{execution_id: execution_id} = entry}, _from, state) do
    by_id = Map.put(state.by_execution_id, execution_id, entry)
    {:reply, :ok, %{state | by_execution_id: by_id}}
  end

  def handle_call({:fetch, execution_id}, _from, state) do
    case Map.fetch(state.by_execution_id, execution_id) do
      {:ok, entry} ->
        {:reply, {:ok, entry}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, execution_id, fun}, _from, state) do
    case Map.fetch(state.by_execution_id, execution_id) do
      {:ok, entry} ->
        case fun.(entry) do
          {:ok, updated} ->
            by_id = Map.put(state.by_execution_id, execution_id, updated)
            {:reply, {:ok, updated}, %{state | by_execution_id: by_id}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, execution_id}, _from, state) do
    {:reply, :ok, %{state | by_execution_id: Map.delete(state.by_execution_id, execution_id)}}
  end

  def handle_call({:list, tenant_id}, _from, state) do
    entries =
      state.by_execution_id
      |> Map.values()
      |> Enum.filter(fn e -> e.tenant_id == tenant_id end)

    {:reply, entries, state}
  end
end
