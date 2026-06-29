defmodule WorkflowStem.Adapters.ControlStore do
  @moduledoc """
  Host adapter for steer-during execution control state.
  """

  alias WorkflowStem.Types

  @callback register_execution(Types.execution_id(), pid(), pos_integer()) ::
              :ok | {:error, term()}
  @callback peek(Types.execution_id()) :: map() | nil
  @callback get_pause_report(Types.execution_id()) :: map() | nil
end
