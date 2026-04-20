defmodule WorkflowStem.Compiler do
  @moduledoc """
  Turns an extended workflow spec (see `WorkflowStem.SpecBehaviour`) into a
  list of ALF component descriptors.

  Bridges the data-only spec format and ALF's full DSL. Specs that declare
  no routes fall through as an empty list — the caller should keep using
  the static `WorkflowStem.Pipelines.Stepwise` pipeline in that case.

  ## Supported primitives (1:1 with ALF DSL — see `deps/alf/lib/dsl.ex`)

      {:stage,      name_or_mod, opts}               # stage/2
      {:switch,     name,        %{key => body}}     # switch/2
      {:composer,   module,      opts}               # composer/2 (fan-out/in)
      {:goto,       name,        opts}               # goto/2
      {:goto_point, name}                            # goto_point/2
      {:done,       name,        opts}               # done/2
      {:dead_end,   name}                            # dead_end/2
      {:from,       module,      opts}               # from/2
      {:plug_with,  module,      body}               # plug_with/2 + do block
      {:tbd,        name}                            # tbd/2

  `opts` is a keyword list (all optional): `:count`, `:opts` (a keyword list
  of user options passed to the component), and `:to`/`:if` for `:goto`,
  `:memo` for `:composer`.

  A state's `:route` may be a single tuple or a list. Inside branches (the
  bodies of `:switch` and `:plug_with`), the contents are lists of the same
  tuple shapes — compiled recursively.

  Descriptors are plain data so they can be inspected in tests and cached
  without ALF being started. A later step will emit these into a real ALF
  module via `Code.compile_quoted/1`.
  """

  alias WorkflowStem.IR

  @type primitive_tuple :: tuple()
  @type descriptor :: {atom(), term(), map()} | {atom(), term()}

  @doc "Returns `true` if any state in the spec declares a `:route`."
  @spec has_routes?(IR.t()) :: boolean()
  def has_routes?(%{} = spec) do
    spec
    |> Map.get(:states, %{})
    |> Enum.any?(fn {_name, state} -> has_route?(state) end)
  end

  @doc """
  Returns a flat list of component descriptors for every `:route` in the
  spec. Each descriptor's `:state` field records the owning state name.

  Raises `ArgumentError` if a `:switch` or `:goto` primitive references a
  routing name absent from the spec's `:routing` map, or if a primitive
  tuple is malformed. Use `validate/1` for a non-raising check.
  """
  @spec components_for(IR.t()) :: [descriptor()]
  def components_for(%{} = spec) do
    spec
    |> Map.get(:states, %{})
    |> Enum.flat_map(fn {state_name, state} ->
      state
      |> route_of()
      |> List.wrap()
      |> Enum.map(&build(&1, state_name, spec))
    end)
  end

  @doc """
  Non-raising spec validation. Walks every route (including nested
  `:switch` branches and `:plug_with` bodies) and checks that each
  `:switch`/`:goto` primitive's routing name resolves.
  """
  @spec validate(IR.t()) :: :ok | {:error, {:missing_routing, atom()} | {:bad_primitive, term()}}
  def validate(%{} = spec) do
    spec
    |> Map.get(:states, %{})
    |> Enum.reduce_while(:ok, fn {_name, state}, :ok ->
      state
      |> route_of()
      |> List.wrap()
      |> walk_primitives(spec)
      |> case do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp has_route?(%{route: _}), do: true
  defp has_route?(%{"route" => _}), do: true
  defp has_route?(_), do: false

  defp route_of(%{route: route}), do: route
  defp route_of(%{"route" => route}), do: route
  defp route_of(_), do: nil

  # ── Build descriptors ───────────────────────────────────────────────

  defp build({:stage, target, opts}, state, _spec) when is_list(opts) do
    {:stage, target, base_meta(state, opts)}
  end

  defp build({:stage, target}, state, _spec) do
    {:stage, target, base_meta(state, [])}
  end

  defp build({:switch, name, branches}, state, spec) when is_map(branches) do
    resolver = fetch_resolver!(spec, name)

    compiled_branches =
      Map.new(branches, fn {branch_key, body} ->
        {branch_key, Enum.map(List.wrap(body), &build(&1, state, spec))}
      end)

    {:switch, name,
     Map.merge(base_meta(state, []), %{resolver: resolver, branches: compiled_branches})}
  end

  defp build({:composer, module, opts}, state, _spec) when is_atom(module) and is_list(opts) do
    meta =
      state
      |> base_meta(opts)
      |> Map.put(:memo, Keyword.get(opts, :memo))

    {:composer, module, meta}
  end

  defp build({:composer, module}, state, _spec) when is_atom(module) do
    {:composer, module, base_meta(state, []) |> Map.put(:memo, nil)}
  end

  defp build({:goto, name, opts}, state, spec) when is_list(opts) do
    resolver = fetch_resolver!(spec, Keyword.get(opts, :if, name))
    to = Keyword.fetch!(opts, :to)

    meta =
      state
      |> base_meta(opts)
      |> Map.merge(%{to: to, resolver: resolver, if: Keyword.get(opts, :if, name)})

    {:goto, name, meta}
  end

  defp build({:goto_point, name}, state, _spec) do
    {:goto_point, name, base_meta(state, [])}
  end

  defp build({:goto_point, name, opts}, state, _spec) when is_list(opts) do
    {:goto_point, name, base_meta(state, opts)}
  end

  defp build({:done, name, opts}, state, _spec) when is_list(opts) do
    {:done, name, base_meta(state, opts)}
  end

  defp build({:done, name}, state, _spec) do
    {:done, name, base_meta(state, [])}
  end

  defp build({:dead_end, name}, state, _spec) do
    {:dead_end, name, base_meta(state, [])}
  end

  defp build({:dead_end, name, opts}, state, _spec) when is_list(opts) do
    {:dead_end, name, base_meta(state, opts)}
  end

  defp build({:from, module, opts}, state, _spec) when is_atom(module) and is_list(opts) do
    {:from, module, base_meta(state, opts)}
  end

  defp build({:from, module}, state, _spec) when is_atom(module) do
    {:from, module, base_meta(state, [])}
  end

  defp build({:plug_with, module, body}, state, spec) when is_atom(module) and is_list(body) do
    compiled_body = Enum.map(body, &build(&1, state, spec))

    {:plug_with, module,
     Map.merge(base_meta(state, []), %{body: compiled_body})}
  end

  defp build({:tbd, name}, state, _spec) do
    {:tbd, name, base_meta(state, [])}
  end

  defp build({:tbd, name, opts}, state, _spec) when is_list(opts) do
    {:tbd, name, base_meta(state, opts)}
  end

  defp build(other, state, _spec) do
    raise ArgumentError,
          "unrecognised :route primitive in state #{inspect(state)}: #{inspect(other)}"
  end

  defp base_meta(state, opts) when is_list(opts) do
    %{
      state: state,
      count: Keyword.get(opts, :count, 1),
      opts: Keyword.get(opts, :opts, [])
    }
  end

  # ── Validation walk (mirrors build/3 but non-raising) ───────────────

  defp walk_primitives(primitives, spec) when is_list(primitives) do
    Enum.reduce_while(primitives, :ok, fn primitive, :ok ->
      case check(primitive, spec) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp check({:switch, name, branches}, spec) when is_map(branches) do
    with :ok <- require_routing(spec, name) do
      branches
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> walk_primitives(spec)
    end
  end

  defp check({:goto, name, opts}, spec) when is_list(opts) do
    require_routing(spec, Keyword.get(opts, :if, name))
  end

  defp check({:plug_with, _module, body}, spec) when is_list(body) do
    walk_primitives(body, spec)
  end

  defp check(tuple, _spec) when is_tuple(tuple), do: :ok
  defp check(other, _spec), do: {:error, {:bad_primitive, other}}

  defp require_routing(spec, name) do
    case IR.routing_for(spec, name) do
      nil -> {:error, {:missing_routing, name}}
      _ -> :ok
    end
  end

  defp fetch_resolver!(spec, name) do
    case IR.routing_for(spec, name) do
      nil ->
        raise ArgumentError,
              "unknown routing name #{inspect(name)} — add it to the spec's :routing map"

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        {mod, fun}

      other ->
        raise ArgumentError,
              "routing entry for #{inspect(name)} must be {module, function}, got: #{inspect(other)}"
    end
  end
end
