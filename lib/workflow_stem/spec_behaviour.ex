defmodule WorkflowStem.SpecBehaviour do
  @moduledoc """
  Behaviour for stem-native workflow specs.

  A workflow is considered *stem-enabled* if a module implementing this behaviour
  exists for the workflow handle.
  """

  @callback workflow_handle() :: String.t()
  @callback spec() :: map()
  @callback artifact() :: %{artifact_hash: String.t(), spec: map()}

  @callback enabled?() :: boolean()
  @optional_callbacks enabled?: 0
end
