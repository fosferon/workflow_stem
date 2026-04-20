defmodule WorkflowStem.Adapters.NotificationAdapter do
  @moduledoc """
  Interface adapter for user-visible notifications and breakpoint signals.

  Any delivery promise MUST have explicit feedback channels (GR-006).
  """

  alias WorkflowStem.Types

  @callback send_email(Types.tenant_id(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback send_sms(Types.tenant_id(), String.t(), map()) :: {:ok, term()} | {:error, term()}

  @callback send_toast(term(), map()) :: {:ok, term()} | {:error, term()}

  @callback notify_breakpoint(Types.tenant_id(), map()) :: {:ok, term()} | {:error, term()}
end

