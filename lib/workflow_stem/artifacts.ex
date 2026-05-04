defmodule WorkflowStem.Artifacts do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Artifacts` under the workflow_stem namespace.

  See `Mobus.Stepwise.Artifacts` for full documentation.
  """

  defdelegate normalize(artifacts), to: Mobus.Stepwise.Artifacts
  defdelegate merge(existing, incoming), to: Mobus.Stepwise.Artifacts
end

