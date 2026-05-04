defmodule WorkflowStem.Application do
  @moduledoc """
  Application callback for workflow_stem.

  Bridges workflow_stem's adapter configuration into mobus_stepwise's
  application env so the foundation engine's `Mobus.Stepwise.Capabilities`
  module sees the correct adapter. This keeps consumer-facing config under
  the `:workflow_stem` key while the foundation reads from `:mobus_stepwise`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    bridge_capability_runner()
    bridge_capability_runner_strict()
    bridge_conversation_handler()

    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: WorkflowStem.Supervisor)
  end

  defp bridge_capability_runner do
    adapter = Application.get_env(:workflow_stem, :capability_runner_adapter)

    if adapter != nil do
      Application.put_env(:mobus_stepwise, :capability_runner_adapter, adapter)
    end
  end

  defp bridge_capability_runner_strict do
    strict =
      Application.get_env(:workflow_stem, :capability_runner_strict) ||
        true

    Application.put_env(:mobus_stepwise, :capability_runner_strict, strict)
  end

  defp bridge_conversation_handler do
    handler = Application.get_env(:workflow_stem, :conversation_handler)

    if handler != nil do
      Application.put_env(:mobus_stepwise, :conversation_handler, handler)
    end
  end
end
