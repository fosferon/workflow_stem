defmodule WorkflowStem.Components.StepwiseEntryAction do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Components.StepwiseEntryAction` under the
  workflow_stem namespace.

  Inherits wait short-circuit: pipeline stages that flag `{:wait, ...}`
  prevent entry actions from firing on top of a pending pause.

  See `Mobus.Stepwise.Components.StepwiseEntryAction` for full documentation.
  """

  defdelegate call(event, opts), to: Mobus.Stepwise.Components.StepwiseEntryAction
end
