# WorkflowStem

Shared workflow runtime for the [Mobus](https://github.com/fosferon) platform — stepwise, FSM, and flow engines backed by [ALF](https://github.com/antonmi/ALF) pipelines.

WorkflowStem provides three workflow profiles, each with a dedicated ALF pipeline and engine:

- **Stepwise** — linear wizard/import flows with back/forward navigation. Delegates to [`mobus_stepwise`](https://hex.pm/packages/mobus_stepwise) for the core engine.
- **FSM** — state-machine workflows with guard/transition/breakpoint semantics.
- **Flow** — pure data pipelines that run a sequence of transformations end-to-end.

Specs are compiled into an intermediate representation (IR) and executed by static ALF pipelines — no per-workflow module generation at runtime. The compiler supports ALF primitives (`stage`, `switch`, `composer`, `goto`, `goto_point`, `done`, `dead_end`, `from`, `plug_with`) for specs that declare custom routes.

## Installation

Add `workflow_stem` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:workflow_stem, "~> 0.2.0"}
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

For specs that declare branching logic, `WorkflowStem.Compiler` translates route definitions into ALF component descriptors:

```elixir
components = WorkflowStem.Compiler.compile(spec)
# Returns e.g. [{:switch, "route_x", %{...}}, {:goto, "skip", ...}, ...]
```

## Documentation

Full API documentation is published at [hexdocs.pm/workflow_stem](https://hexdocs.pm/workflow_stem).

## License

MIT
