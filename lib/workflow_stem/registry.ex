defmodule WorkflowStem.Registry do
  @moduledoc """
  Registry for stem-native workflow specs + per-agent pipeline instances.

  Specs are discovered by scanning a configurable OTP application's module list
  for modules matching a prefix that implement `WorkflowStem.SpecBehaviour`.

  Configuration (in config/*.exs):

      config :workflow_stem,
        spec_discovery: {:my_app, "Elixir.MyApp.Workflows.Specs."}

  If `spec_discovery` is not set, defaults to scanning `:workflow_stem` itself.

  This keeps stem enablement ergonomic (no per-workflow config allowlists) while
  remaining predictable (we only scan the application module list, not the filesystem).

  ## Per-agent pipeline instances

  When a spec declares `:route` primitives (see `WorkflowStem.SpecBehaviour`),
  each agent gets its own compiled ALF pipeline instance keyed on
  `{agent_id, workflow_handle}`. `ensure_instance/2` lazily compiles and
  caches the module via `:persistent_term`; `release_instance/2` stops and
  evicts it (e.g. on persona change / hot-swap).

  Specs without routes fall through to the shared static
  `WorkflowStem.Pipelines.Stepwise` pipeline — no per-agent compilation
  happens and all existing workflows keep working unchanged.
  """

  alias WorkflowStem.{Compiler, SpecBehaviour}
  alias WorkflowStem.Pipeline.Builder

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

  # ── Per-agent pipeline instance cache ────────────────────────────────

  @doc """
  Ensure a pipeline instance exists for `{agent_id, workflow_handle}` and
  return the module to call.

  Behaviour:
    * If the spec declares no `:route` primitives, returns the shared
      `WorkflowStem.Pipelines.Stepwise` module. No per-agent compilation.
    * Otherwise, compiles (if not already cached) an ALF module via
      `WorkflowStem.Pipeline.Builder`, starts it, caches it, and returns
      the module.
  """
  @spec ensure_instance(term(), String.t()) :: {:ok, module()} | {:error, term()}
  def ensure_instance(agent_id, workflow_handle) when is_binary(workflow_handle) do
    case spec_module_for(workflow_handle) do
      nil ->
        {:error, {:unknown_workflow, workflow_handle}}

      spec_mod ->
        ensure_instance(agent_id, workflow_handle, spec_mod.spec())
    end
  end

  @doc """
  Variant that accepts the spec map directly, bypassing module discovery.

  Useful for callers that already have the spec in hand (e.g. Atrapos
  loading a persona YAML) and for tests where the spec module isn't
  registered in `:application.get_key/2`.
  """
  @spec ensure_instance(term(), String.t(), map()) :: {:ok, module()} | {:error, term()}
  def ensure_instance(agent_id, workflow_handle, spec)
      when is_binary(workflow_handle) and is_map(spec) do
    if Compiler.has_routes?(spec) do
      ensure_compiled_instance(agent_id, workflow_handle, spec)
    else
      {:ok, WorkflowStem.Pipelines.Stepwise}
    end
  end

  @doc """
  Return a cached pipeline instance module for `{agent_id, workflow_handle}`,
  or `nil` if none has been compiled yet.
  """
  @spec instance_module(term(), String.t()) :: module() | nil
  def instance_module(agent_id, workflow_handle) when is_binary(workflow_handle) do
    :persistent_term.get(instance_key(agent_id, workflow_handle), nil)
  end

  @doc """
  Stop and evict a cached pipeline instance. Safe to call even if no
  instance was ever compiled. Next `ensure_instance/2` call will
  re-compile from the current spec.
  """
  @spec release_instance(term(), String.t()) :: :ok
  def release_instance(agent_id, workflow_handle) when is_binary(workflow_handle) do
    key = instance_key(agent_id, workflow_handle)

    case :persistent_term.get(key, nil) do
      nil ->
        :ok

      mod ->
        try_stop(mod)
        :persistent_term.erase(key)
        :ok
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp ensure_compiled_instance(agent_id, workflow_handle, spec) do
    key = instance_key(agent_id, workflow_handle)

    case :persistent_term.get(key, nil) do
      nil ->
        with :ok <- validate_spec(spec),
             descriptors <- Compiler.components_for_engine(spec),
             routing <- Compiler.engine_routing(spec),
             module_name <- generated_module_name(agent_id, workflow_handle),
             {:ok, mod} <- Builder.build(module_name, descriptors, routing),
             :ok <- ensure_started(mod) do
          :persistent_term.put(key, mod)
          {:ok, mod}
        end

      mod ->
        {:ok, mod}
    end
  end

  defp validate_spec(spec) do
    case Compiler.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_started(mod) do
    if function_exported?(mod, :start, 0) do
      mod.start()
      :ok
    else
      :ok
    end
  end

  defp try_stop(mod) do
    if function_exported?(mod, :stop, 0) do
      try do
        mod.stop()
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp instance_key(agent_id, workflow_handle) do
    {__MODULE__, :instance, agent_id, workflow_handle}
  end

  defp generated_module_name(agent_id, workflow_handle) do
    Module.concat([
      WorkflowStem.Generated,
      sanitize(agent_id),
      sanitize(workflow_handle)
    ])
  end

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]/, "_")
  end
end
