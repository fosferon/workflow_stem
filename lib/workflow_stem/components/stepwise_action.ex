defmodule WorkflowStem.Components.StepwiseAction do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Components.StepwiseAction` under the
  workflow_stem namespace.

  The foundation module supports both `:capability` and `:conversation`
  action types with fully generalized contracts — no consumer-specific
  vocabulary.

  See `Mobus.Stepwise.Components.StepwiseAction` for full documentation.
  """

  defdelegate call(event, opts), to: Mobus.Stepwise.Components.StepwiseAction

  @doc false
  defdelegate run_entry_action(event), to: Mobus.Stepwise.Components.StepwiseAction
end
