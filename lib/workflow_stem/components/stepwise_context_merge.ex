defmodule WorkflowStem.Components.StepwiseContextMerge do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Components.StepwiseContextMerge` under the
  workflow_stem namespace.

  See `Mobus.Stepwise.Components.StepwiseContextMerge` for full
  documentation.
  """

  defdelegate call(event, opts), to: Mobus.Stepwise.Components.StepwiseContextMerge
end

