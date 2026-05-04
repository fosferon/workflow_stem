defmodule WorkflowStem.Components.StepwiseEntryAction do
  @moduledoc """
  Executes entry-triggered actions for `:stepwise` workflows.

  Runs immediately after a state transition when the new state defines an
  action with an `:enter` trigger (or equivalent definition).

  ## Wait short-circuit

  When the preceding `StepwiseAction` stage or the entry action itself sets
  `event.wait` (capability returned `{:wait, ...}`), this stage
  short-circuits — no further entry actions are fired on top of the pending
  pause.
  """

  alias WorkflowStem.Components.StepwiseAction

  @spec call(map(), map()) :: map()
  def call(%{status: :error} = event, _opts), do: event
  def call(%{skip_transition: true} = event, _opts), do: event
  # Upstream capability already yielded wait — don't run another entry action.
  def call(%{wait: wait} = event, _opts) when not is_nil(wait), do: event

  def call(%{state_changed?: true} = event, _opts) do
    case StepwiseAction.run_entry_action(event) do
      %{wait: wait} = out when not is_nil(wait) -> out
      other -> other
    end
  end

  def call(event, _opts), do: event
end
