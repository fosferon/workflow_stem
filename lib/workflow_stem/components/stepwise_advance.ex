defmodule WorkflowStem.Components.StepwiseAdvance do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Components.StepwiseAdvance` under the
  workflow_stem namespace.

  Inherits foundation hardening: wait short-circuit, transition-policy
  hooks, and full history/trace recording on state transitions.

  See `Mobus.Stepwise.Components.StepwiseAdvance` for full documentation.
  """

  defdelegate call(event, opts), to: Mobus.Stepwise.Components.StepwiseAdvance
end
