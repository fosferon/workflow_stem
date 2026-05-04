defmodule WorkflowStem.Components.FsmBreakpoint do
  @moduledoc """
  Re-exports `Mobus.Stepwise.Components.FsmBreakpoint` under the
  workflow_stem namespace.

  See `Mobus.Stepwise.Components.FsmBreakpoint` for full documentation.
  """

  defdelegate call(event, opts), to: Mobus.Stepwise.Components.FsmBreakpoint
end

