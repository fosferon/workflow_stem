defmodule WorkflowStem.Adapters.ProcessController do
  @moduledoc """
  Host adapter for active subprocess control.

  Hosts own the actual process model. The shared runner only requires an
  adapter seam so later CLI-dispatch implementations can thread host context,
  provenance, and budget state through process startup and interruption.
  """

  alias WorkflowStem.Types

  @callback register_active(Types.execution_id(), term(), map()) :: :ok | {:error, term()}
  @callback clear_active(Types.execution_id()) :: :ok | {:error, term()}
  @callback halt_active(Types.execution_id(), term(), map()) :: :ok | {:error, term()}
end
