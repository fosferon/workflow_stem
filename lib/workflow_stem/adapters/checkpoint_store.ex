defmodule WorkflowStem.Adapters.CheckpointStore do
  @moduledoc """
  Host adapter for runtime checkpoints and terminal status updates.
  """

  alias WorkflowStem.Types

  @callback checkpoint(map(), map()) :: :ok | {:error, term()}
  @callback restore(Types.execution_id(), map()) :: {:ok, map()} | {:error, term()}
  @callback mark_status(Types.execution_id(), String.t()) :: :ok | {:error, term()}
end
