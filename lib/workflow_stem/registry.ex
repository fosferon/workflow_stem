defmodule WorkflowStem.Registry do
  @moduledoc """
  Registry for stem-native workflow specs.

  Specs are discovered by scanning a configurable OTP application's module list
  for modules matching a prefix that implement `WorkflowStem.SpecBehaviour`.

  Configuration (in config/*.exs):

      config :workflow_stem,
        spec_discovery: {:my_app, "Elixir.MyApp.Workflows.Specs."}

  If `spec_discovery` is not set, defaults to scanning `:workflow_stem` itself.

  This keeps stem enablement ergonomic (no per-workflow config allowlists) while
  remaining predictable (we only scan the application module list, not the filesystem).
  """

  alias WorkflowStem.SpecBehaviour

  @spec enabled?(String.t() | nil) :: boolean()
  def enabled?(nil), do: false

  def enabled?(workflow_handle) when is_binary(workflow_handle) do
    case spec_module_for(workflow_handle) do
      nil -> false
      mod -> spec_enabled?(mod)
    end
  end

  @spec spec_module_for(String.t()) :: module() | nil
  def spec_module_for(workflow_handle) when is_binary(workflow_handle) do
    Enum.find(spec_modules(), fn mod ->
      mod.workflow_handle() == workflow_handle
    end)
  end

  @spec spec_modules() :: [module()]
  def spec_modules do
    {app, prefix} = discovery_config()

    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        Enum.filter(modules, &spec_module?(&1, prefix))

      _ ->
        []
    end
  end

  defp discovery_config do
    Application.get_env(:workflow_stem, :spec_discovery, {:workflow_stem, "Elixir.WorkflowStem.Specs."})
  end

  defp spec_module?(mod, prefix) when is_atom(mod) do
    Code.ensure_loaded?(mod) and
      function_exported?(mod, :workflow_handle, 0) and
      behaviour?(mod) and
      String.starts_with?(Atom.to_string(mod), prefix)
  end

  defp behaviour?(mod) do
    behaviours = mod.module_info(:attributes)[:behaviour] || []
    SpecBehaviour in behaviours
  end

  defp spec_enabled?(mod) do
    if function_exported?(mod, :enabled?, 0) do
      mod.enabled?()
    else
      true
    end
  end
end
