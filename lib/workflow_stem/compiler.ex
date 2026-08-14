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
  Returns the full engine-topology descriptor list for a spec, ready to
  be emitted via `WorkflowStem.Pipeline.Builder.build/3`.

  The topology mirrors the static `WorkflowStem.Pipelines.Stepwise`
  pipeline but replaces its single `StepwiseAction` stage with a
  `switch(:__current_state__, branches: ...)` that dispatches per-state:

      [
        stage(StepwiseContextMerge),
        switch(:__current_state__, branches: %{
          state_a: <descriptors from state_a's :route, or default>,
          state_b: <descriptors from state_b's :route, or default>,
          ...
        }),
        stage(StepwiseAdvance),
        stage(StepwiseEntryAction),
        stage(FsmBreakpoint),
        stage(StepwiseProjection)
      ]

  States without a `:route` get a default body of `[stage(StepwiseAction)]`
  so the existing per-state action dispatcher keeps working for them.

  Use `engine_routing/1` to get the routing-resolver map that must
  accompany these descriptors when calling `Builder.build/3`.
  """
  @spec components_for_engine(IR.t()) :: [descriptor()]
  def components_for_engine(%{} = spec) do
    states = Map.get(spec, :states, %{})

    state_branches =
      Map.new(states, fn {state_name, state_data} ->
        body = state_branch_body(state_data, state_name, spec)
        {state_name, body}
      end)

    switch_descriptor =
      {:switch, :__current_state__,
       %{
         state: :__wrapper__,
         count: 1,
         opts: [],
         resolver: {WorkflowStem.Compiler.Resolvers, :current_state},
         branches: state_branches
       }}

    [
      stage_descriptor(WorkflowStem.Components.StepwiseContextMerge),
      switch_descriptor,
      stage_descriptor(WorkflowStem.Components.StepwiseAdvance),
      stage_descriptor(WorkflowStem.Components.StepwiseEntryAction),
      stage_descriptor(WorkflowStem.Components.FsmBreakpoint),
      stage_descriptor(WorkflowStem.Components.StepwiseProjection)
    ]
  end

  @doc """
  Returns the routing map that must be passed to `Builder.build/3`
  alongside `components_for_engine/1`.

  Merges the spec's user-declared `:routing` with the internal
  `:__current_state__` delegate that the synthesised wrapper switch
  needs to resolve.
  """
  @spec engine_routing(IR.t()) :: map()
  def engine_routing(%{} = spec) do
    user_routing = Map.get(spec, :routing, %{})

    Map.put(
      user_routing,
      :__current_state__,
      {WorkflowStem.Compiler.Resolvers, :current_state}
    )
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

  defp state_branch_body(state_data, state_name, spec) do
    case route_of(state_data) do
      nil ->
        # Default: the existing per-state action dispatcher. Same
        # behaviour as a state without :route today.
        [stage_descriptor(WorkflowStem.Components.StepwiseAction)]

      route ->
        route
        |> List.wrap()
        |> Enum.map(&build(&1, state_name, spec))
    end
  end

  defp stage_descriptor(module) when is_atom(module) do
    {:stage, module, %{state: :__wrapper__, count: 1, opts: []}}
  end

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

    {:plug_with, module, Map.merge(base_meta(state, []), %{body: compiled_body})}
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
    with :ok <- validate_opts(opts) do
      require_routing(spec, Keyword.get(opts, :if, name))
    end
  end

  defp check({:plug_with, module, body}, spec) when is_atom(module) and is_list(body) do
    walk_primitives(body, spec)
  end

  defp check({:stage, _target}, _spec), do: :ok
  defp check({:stage, _target, opts}, _spec), do: validate_opts(opts)
  defp check({:composer, module}, _spec) when is_atom(module), do: :ok
  defp check({:composer, module, opts}, _spec) when is_atom(module), do: validate_opts(opts)
  defp check({:goto_point, _name}, _spec), do: :ok
  defp check({:goto_point, _name, opts}, _spec), do: validate_opts(opts)
  defp check({:done, _name}, _spec), do: :ok
  defp check({:done, _name, opts}, _spec), do: validate_opts(opts)
  defp check({:dead_end, _name}, _spec), do: :ok
  defp check({:dead_end, _name, opts}, _spec), do: validate_opts(opts)
  defp check({:from, module}, _spec) when is_atom(module), do: :ok
  defp check({:from, module, opts}, _spec) when is_atom(module), do: validate_opts(opts)
  defp check({:tbd, _name}, _spec), do: :ok
  defp check({:tbd, _name, opts}, _spec), do: validate_opts(opts)
  defp check(other, _spec), do: {:error, {:bad_primitive, other}}

  defp validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:bad_primitive_options, opts}}
  end

  defp validate_opts(opts), do: {:error, {:bad_primitive_options, opts}}

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
