defmodule WorkflowStem.Types do
  @moduledoc """
  Canonical types for the workflow stem.

  The stem is the thin-waist contract between:
  - host application (projection + events)
  - `workflow_stem` (runtime)
  - host adapters (persistence, notifications, capabilities)
  """

  @type tenant_id :: String.t()
  @type workflow_handle :: String.t() | atom()
  @type artifact_hash :: String.t()

  @type execution_id :: String.t()
  @type profile :: :flow | :fsm | :stepwise

  @type spec :: map()
  @type ir :: map()
  @type runtime_context :: map()
  @type runtime :: map()

  @type event :: atom() | String.t()
  @type payload :: map()

  @type wait_cfg :: map()
  @type reason :: term()
end
