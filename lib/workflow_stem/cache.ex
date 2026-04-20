defmodule WorkflowStem.Cache do
  @moduledoc """
  ETS-backed cache for compiled workflow IR.

  Keyed by `{tenant_id, workflow_handle, artifact_hash}` to enforce tenant isolation.

  This is intentionally simple: hot-reload is achieved by invalidation/eviction,
  not code loading or module generation.
  """

  alias WorkflowStem.Types

  @table __MODULE__

  @spec ensure_started() :: :ok
  def ensure_started do
    WorkflowStem.CacheOwner.ensure_table()
    :ok
  end

  @spec get({Types.tenant_id(), Types.workflow_handle(), Types.artifact_hash()}) ::
          {:ok, Types.ir()} | :miss
  def get(key) do
    ensure_started()

    try do
      case :ets.lookup(@table, key) do
        [{^key, ir}] -> {:ok, ir}
        _ -> :miss
      end
    rescue
      ArgumentError ->
        # Table may have been recreated; retry once.
        ensure_started()

        case :ets.lookup(@table, key) do
          [{^key, ir}] -> {:ok, ir}
          _ -> :miss
        end
    end
  end

  @spec put({Types.tenant_id(), Types.workflow_handle(), Types.artifact_hash()}, Types.ir()) :: :ok
  def put(key, ir) when is_map(ir) do
    ensure_started()
    true = :ets.insert(@table, {key, ir})
    :ok
  end

  @spec invalidate(Types.tenant_id(), Types.workflow_handle()) :: non_neg_integer()
  def invalidate(tenant_id, workflow_handle) do
    ensure_started()

    try do
      :ets.match_delete(@table, {{tenant_id, workflow_handle, :_}, :_})
      :ets.info(@table, :size)
    rescue
      ArgumentError ->
        ensure_started()
        :ets.match_delete(@table, {{tenant_id, workflow_handle, :_}, :_})
        :ets.info(@table, :size)
    end
  end
end
