# WorkflowStem

Shared workflow runtime — stepwise, FSM, and flow engines backed by [ALF](https://github.com/antonmi/ALF) pipelines.

WorkflowStem provides three workflow profiles, each with a dedicated ALF pipeline and engine:

- **Stepwise** — linear wizard/import flows with back/forward navigation. Delegates to [`mobus_stepwise`](https://hex.pm/packages/mobus_stepwise) for the core engine.
- **Runner** — a host-parameterized execution runner that owns the FSM walk, wait/resume loop, control checks, checkpoint hooks, and canonical event emission. Hosts plug in persistence, publication, and control state through adapter behaviours.
- **FSM** — state-machine workflows with guard/transition/breakpoint semantics.
- **Flow** — pure data pipelines that run a sequence of transformations end-to-end.

Specs are compiled into an intermediate representation (IR). Specs without
custom routes use the static ALF pipelines; routed specs are validated and
compiled into cached per-workflow ALF modules at runtime. The compiler supports
all ten ALF primitives: `stage`, `switch`, `composer`, `goto`, `goto_point`,
`done`, `dead_end`, `from`, `plug_with`, and `tbd`.

## Installation

Add `workflow_stem` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:workflow_stem, "~> 0.3.0"}
  ]
end
```

## Quick Start

### 1. Define a spec

A spec describes the workflow profile, steps/states, transitions, and per-step metadata:

```elixir
spec = %{
  profile: :stepwise,
  initial_state: :step_one,
  steps: [:step_one, :step_two, :step_three],
  states: %{
    step_one: %{
      action: {:capability, :collect_name},
      projection: %{title: "What is your name?"}
    },
    step_two: %{
      action: {:capability, :collect_email},
      projection: %{title: "Email address"}
    },
    step_three: %{
      action: {:capability, :submit},
      projection: %{title: "Review & submit"}
    }
  }
}
```

### 2. Compile to IR

```elixir
{:ok, ir} = WorkflowStem.Loader.get_or_compile("tenant_1", "my_workflow", spec)
```

### 3. Run through an engine

```elixir
alias WorkflowStem.Engines.StepwiseEngine

runtime = %{
  execution_id: "ex_123",
  tenant_id: "tenant_1",
  spec: spec,
  ir: ir
}

{:ok, projection} = StepwiseEngine.init(runtime)
{:ok, projection} = StepwiseEngine.advance(runtime, %{input: "Leonidas"})
```

## Runner

`WorkflowStem.Runner` is a host-parameterized execution runner. It owns the
FSM walk, wait/resume loop, control checks, checkpoint hooks, and canonical
event emission. Hosts provide persistence, live publication, and control
state through adapter behaviours (`EventSink`, `ControlStore`,
`CheckpointStore`).

```elixir
alias WorkflowStem.Runner

{:ok, execution_id} =
  Runner.start(spec, inputs,
    tenant_id: "tenant_1",
    execution_id: "exec_123",
    event_sink: MyApp.EventSink,
    control_store: MyApp.ControlStore,
    checkpoint_store: MyApp.CheckpointStore
  )
```

Events are appended durably first, then published for live subscribers. Late
subscribers replay through the same `EventSink`:

```elixir
{:ok, events} = WorkflowStem.Runner.replay(MyApp.EventSink, "tenant_1", "exec_123")
```

## Architecture

```
Spec (map)
  │
  ▼
Loader ──► IR (normalized map)
  │
  ├── StepwiseEngine ──► Pipelines.Stepwise (ALF)
  ├── FsmEngine       ──► Pipelines.Fsm (ALF)
  └── FlowEngine      ──► Pipelines.Flow (ALF)
```

Each engine feeds events into its ALF pipeline. Components (`FsmGuard`, `FsmAction`, `FsmTransition`, `FlowAction`, `FlowProjection`, etc.) process events in sequence. Projections are returned to the caller for rendering.

### Adapters

Engines delegate side-effects to configured adapters:

- `capability_runner_adapter` — executes capabilities/actions
- `persistence_adapter` — stores execution state
- `notification_adapter` — sends notifications
- `conversation_handler` — handles conversational UI turns

Configure them under the `:workflow_stem` application env:

```elixir
config :workflow_stem,
  capability_runner_adapter: MyApp.CapabilityRunner,
  persistence_adapter: MyApp.Persistence,
  notification_adapter: MyApp.Notifications
```

### Compiler & custom routes

For specs that declare custom routing, `WorkflowStem.Compiler` validates the
IR and translates route definitions into ALF component descriptors. The
registry normally performs this automatically; direct builder use looks like:

```elixir
alias WorkflowStem.{Compiler, Pipeline.Builder}

:ok = Compiler.validate(ir)
components = Compiler.components_for_engine(ir)
routing = Compiler.engine_routing(ir)
{:ok, pipeline_module} = Builder.build(MyApp.MyWorkflowPipeline, components, routing)
```

## Documentation

Full API documentation is published at [hexdocs.pm/workflow_stem](https://hexdocs.pm/workflow_stem).

## License

MIT
