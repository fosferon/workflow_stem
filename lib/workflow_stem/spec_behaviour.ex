defmodule WorkflowStem.SpecBehaviour do
  @moduledoc """
  Behaviour for stem-native workflow specs.

  A workflow is considered *stem-enabled* if a module implementing this behaviour
  exists for the workflow handle.

  ## Spec shape

  The map returned by `spec/0` supports the following top-level keys:

    * `:id`             — workflow handle (same as `workflow_handle/0`)
    * `:profile`        — `:stepwise | :fsm | :flow`
    * `:persona`        — optional persona slug loaded by hosts
    * `:initial_state`  — atom naming the starting state
    * `:states`         — `%{state_name => state_map}`
    * `:transitions`    — `%{event => %{to: state_name}}`
    * `:routing`        — **optional**, `%{route_name => {module, function}}`
                          maps each route name referenced in a state's `:route`
                          to the MFA-like resolver that returns the branch key
                          at runtime. The resolver must be a pure function of
                          `(event, opts)` returning the branch key.

  ### Per-state `:route` (ALF primitives)

  A state may declare `:route` instead of (or alongside) `:action`. All ten
  ALF DSL macros are exposed 1:1 — see `deps/alf/lib/dsl.ex`:

      {:stage,      name_or_mod, opts}          # stage/2 — basic step
      {:switch,     name,        %{key => body}} # switch/2 — branch on resolver
      {:composer,   module,      opts}          # composer/2 — fan-out/in, :memo
      {:goto,       name,        opts}          # goto/2 — jump to labelled point
      {:goto_point, name}                       # goto_point/2 — label marker
      {:done,       name,        opts}          # done/2 — drop packet (terminal)
      {:dead_end,   name}                       # dead_end/2 — packet terminator
      {:from,       module,      opts}          # from/2 — inline other pipeline
      {:plug_with,  module,      body}          # plug_with/2 — plug + body + unplug
      {:tbd,        name}                       # tbd/2 — placeholder, compiles noop

  `opts` is a keyword list (all optional): `:count`, `:opts` (user options),
  plus primitive-specific keys — `:to`/`:if` for `:goto`, `:memo` for
  `:composer`.

  `:route` may be a single primitive tuple or a list of them. Inside
  branches (`:switch` bodies, `:plug_with` bodies), the contents are lists
  of the same tuple shapes — compiled recursively. Examples:

      %{route: {:switch, :triage, %{simple: [{:stage, :s1}],
                                    deep:   [{:stage, :s2}, {:done, :end}]}}}

      %{route: [
        {:stage, :prep},
        {:switch, :route, %{a: [...], b: [...]}},
        {:done, :terminal}
      ]}

  Every `:switch` or `:goto` name MUST appear as a key in the top-level
  `:routing` map, mapping to a pure `{module, function}` resolver with
  signature `(event, opts) -> branch_key | boolean`. `WorkflowStem.Compiler`
  materialises the whole tree into ALF components.

  Backwards compatibility: specs without `:route` or `:routing` continue to
  run on the static `WorkflowStem.Pipelines.Stepwise` pipeline exactly as
  before (state-machine transitions via `StepwiseAdvance`).
  """

  @callback workflow_handle() :: String.t()
  @callback spec() :: map()
  @callback artifact() :: %{artifact_hash: String.t(), spec: map()}

  @callback enabled?() :: boolean()
  @optional_callbacks enabled?: 0
end
