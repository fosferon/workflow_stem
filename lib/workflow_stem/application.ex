defmodule WorkflowStem.Application do
  @moduledoc """
  Application callback for workflow_stem.

  Bridges workflow_stem's adapter configuration into mobus_stepwise's
  application env so the foundation engine's `Mobus.Stepwise.Capabilities`
  module sees the correct adapter. This keeps consumer-facing config under
  the `:workflow_stem` key while the foundation reads from `:mobus_stepwise`.

  ## Startup-only bridging

  Bridging happens once at application start. If a consumer changes
  adapter config at runtime via `Application.put_env(:workflow_stem, ...)`,
  call `rebridge/0` to propagate the change to mobus_stepwise's env.
  Test helpers and interactive development are the primary use cases;
  production config is typically set at compile/startup.

  ## Defaults

  `:capability_runner_strict` defaults to `true` (unlike the foundation's
  `false`). Rationale: workflow_stem consumers always configure a capability
  runner adapter, so a nil adapter signals a misconfiguration. The test
  helper at `test/test_helper.exs` sets this explicitly so tests are
  self-documenting.
  """

  use Application

  @impl true
  def start(_type, _args) do
    rebridge()

    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: WorkflowStem.Supervisor)
  end

  @doc """
  Re-bridges all adapter config from `:workflow_stem` to `:mobus_stepwise`.

  Call this after changing adapter config at runtime. Idempotent and safe
  to call multiple times.
  """
  @spec rebridge() :: :ok
  def rebridge do
    bridge_capability_runner()
    bridge_capability_runner_strict()
    bridge_conversation_handler()
    :ok
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
