defmodule WorkflowStem.Pipeline.Builder do
  @moduledoc """
  Emits a runtime-compiled ALF pipeline module from a spec's compiled
  descriptors.

  Takes descriptors produced by `WorkflowStem.Compiler.components_for/1`
  plus the spec's `:routing` table, and generates an Elixir module that:

    * does `use ALF.DSL`
    * exposes `@components [...]` matching the descriptor list
    * carries `defdelegate` entries for every routing name, so ALF's
      `switch`/`goto` components resolve via `apply(pipeline_mod, name, args)`

  The generated module is compiled into the current BEAM via
  `Code.compile_quoted/1`. Callers get back `{:ok, module_name}`; the
  module is callable immediately.

  Typical usage:

      {:ok, mod} =
        WorkflowStem.Pipeline.Builder.build(
          MyAgent.Pipeline.SomeWorkflow,
          Compiler.components_for(spec),
          Map.get(spec, :routing, %{})
        )

      :ok = mod.start()
      result = mod.call(event)

  ## Scope in this iteration

  AST emission is implemented for: `stage`, `switch`, `composer`, `goto`,
  `goto_point`, `done`, `dead_end`, `from`, `tbd`. Support for `plug_with`
  follows the same pattern but is not yet emitted — a descriptor of
  `{:plug_with, ...}` will raise here. (The Compiler accepts and validates
  it; Builder just hasn't rendered the AST yet.)
  """

  @doc """
  Build and compile a pipeline module. Returns `{:ok, module}` on success.

  Raises `ArgumentError` if a descriptor has no AST emitter yet
  (currently `:plug_with`).
  """
  @spec build(module(), [tuple()], map()) :: {:ok, module()}
  def build(module_name, descriptors, routing)
      when is_atom(module_name) and is_list(descriptors) and is_map(routing) do
    components_ast = Enum.map(descriptors, &descriptor_ast/1)
    delegates_ast = Enum.map(routing, &delegate_ast/1)

    module_ast =
      quote do
        defmodule unquote(module_name) do
          use ALF.DSL

          unquote_splicing(delegates_ast)

          @components unquote(components_ast)

          # Mirror the idempotent start convention used by
          # WorkflowStem.Pipelines.Stepwise so StepwiseEngine can call
          # pipeline_mod.ensure_started/1 uniformly for static + generated.
          @spec ensure_started(keyword()) :: :ok | {:error, term()}
          def ensure_started(opts \\ []) do
            case Process.whereis(__MODULE__) do
              nil -> __MODULE__.start(opts)
              _pid -> :ok
            end
          end
        end
      end

    [{^module_name, _bin} | _] = Code.compile_quoted(module_ast)
    {:ok, module_name}
  end

  # ── Descriptor → AST ────────────────────────────────────────────────

  defp descriptor_ast({:stage, target, meta}) do
    opts = meta_opts(meta)

    quote do
      stage(unquote(target), unquote(opts))
    end
  end

  defp descriptor_ast({:switch, name, meta}) do
    branches_ast = branches_to_ast(meta.branches)
    opts = Keyword.put(meta_opts(meta), :branches, branches_ast)

    quote do
      switch(unquote(name), unquote(opts))
    end
  end

  defp descriptor_ast({:composer, module, meta}) do
    base_opts = meta_opts(meta)

    opts =
      case Map.get(meta, :memo) do
        nil -> base_opts
        memo -> Keyword.put(base_opts, :memo, memo)
      end

    quote do
      composer(unquote(module), unquote(opts))
    end
  end

  defp descriptor_ast({:goto, name, meta}) do
    opts = meta_opts(meta) |> Keyword.put(:to, meta.to)

    quote do
      goto(unquote(name), unquote(opts))
    end
  end

  defp descriptor_ast({:goto_point, name, meta}) do
    opts = [count: Map.get(meta, :count, 1)]

    quote do
      goto_point(unquote(name), unquote(opts))
    end
  end

  defp descriptor_ast({:done, name, meta}) do
    opts = meta_opts(meta)

    quote do
      done(unquote(name), unquote(opts))
    end
  end

  defp descriptor_ast({:dead_end, name, meta}) do
    opts = [count: Map.get(meta, :count, 1)]

    quote do
      dead_end(unquote(name), unquote(opts))
    end
  end

  defp descriptor_ast({:from, module, meta}) do
    opts = meta_opts(meta)

    quote do
      from(unquote(module), unquote(opts))
    end
  end

  defp descriptor_ast({:tbd, name, _meta}) do
    quote do
      tbd(unquote(name))
    end
  end

  defp descriptor_ast({:plug_with, _module, _meta}) do
    raise ArgumentError,
          "Builder: AST emission for :plug_with not yet implemented. The descriptor is accepted by Compiler; add emission here when a consumer needs it."
  end

  defp descriptor_ast(other) do
    raise ArgumentError, "Builder: unknown descriptor shape: #{inspect(other)}"
  end

  # ── Branches: map of {key => [descriptors]} → AST map ───────────────

  defp branches_to_ast(branches) when is_map(branches) do
    pairs =
      Enum.map(branches, fn {key, body} ->
        {key, Enum.map(body, &descriptor_ast/1)}
      end)

    {:%{}, [], pairs}
  end

  # ── Meta → keyword opts accepted by ALF.DSL macros ──────────────────

  defp meta_opts(meta) do
    count = Map.get(meta, :count, 1)
    opts = Map.get(meta, :opts, [])
    [count: count, opts: opts]
  end

  # ── Routing → defdelegate AST ───────────────────────────────────────

  defp delegate_ast({name, {module, fun}})
       when is_atom(name) and is_atom(module) and is_atom(fun) do
    quote do
      defdelegate unquote(name)(event, opts), to: unquote(module), as: unquote(fun)
    end
  end
end
