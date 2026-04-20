defmodule WorkflowStem.CacheOwner do
  @moduledoc false

  use GenServer

  @name __MODULE__
  @table WorkflowStem.Cache

  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(@name) do
      nil ->
        # Intentionally not linked (Phase 2): keep ETS ownership stable across async tests.
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

  @spec ensure_table() :: :ok
  def ensure_table do
    ensure_started()
    GenServer.call(@name, :ensure_table)
  end

  @impl true
  def init(state) do
    _ = ensure_table_exists()
    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    _ = ensure_table_exists()
    {:reply, :ok, state}
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        :ok
    end
  rescue
    # Race: someone created it after our whereis check.
    ArgumentError -> :ok
  end
end
