# Changelog

## Unreleased

### Added

- Runtime pipeline generation now emits recursive `plug_with` bodies, including
  nested route primitives.

### Changed

- Route validation rejects malformed primitive options and `goto` declarations
  without a required `to` target before runtime AST emission.

## v0.3.1 (June 2026) — Public release hygiene

### Changed

- **Documentation cleanup.** Rewrote the changelog and trimmed internal-only
  framing from module docs so the package reads as a standalone library.
- `CHANGELOG.md` is now included in the Hex package files list.

## v0.3.0 (June 2026) — Host-parameterized Runner

### Added

- **`WorkflowStem.Runner`** — a host-parameterized execution runner that owns
  the FSM walk, wait/resume loop, control checks, checkpoint hooks, and
  canonical event emission. Hosts plug in persistence, live publication, and
  control state through adapter behaviours.
  - `start/3`, `start_from_runtime/2`, and `replay/3` with tenant-scoped
    executions, durable ordered events, and safe adapter calls.
- **`WorkflowStem.EventLog`** — an append-then-publish facade: append the
  canonical event durably, publish the persisted copy, and replay for late
  subscribers.
- **Adapter behaviours**: `Adapters.EventSink`, `Adapters.ControlStore`,
  `Adapters.CheckpointStore`, `Adapters.CapabilityInvoker`, and
  `Adapters.ProcessController`.

### Changed

- `mobus_stepwise` dependency switched from a git ref to the Hex `0.2.0`
  release.

## v0.2.0 (May 2026) — Engine delegation & conversation generalization

### Added

- **Dependency on `mobus_stepwise`.** The shared stepwise substrate (engine,
  capabilities, several components) now comes from the
  [`mobus_stepwise`](https://hex.pm/packages/mobus_stepwise) package. Roughly
  440 lines of duplicated substrate were replaced with `defdelegate`.
- **`WorkflowStem.Application`** — bridges `:workflow_stem` adapter config keys
  into `:mobus_stepwise` application env at startup. Consumers configure
  `:workflow_stem` keys; the engine reads them transparently from
  `:mobus_stepwise`.
- **`extensions` field** on `WorkflowStem.Projection`, structurally compatible
  with the engine's projection. The `build_extensions/2` hook respects
  `spec.projection_enricher`.

### Changed

- **`StepwiseEngine` is now a thin shim** over `Mobus.Stepwise.Engine`.
  `init`/`handle_event`/`restore` delegate to the engine; projection structs
  are converted on the way back. The shim injects
  `WorkflowStem.Pipelines.Stepwise` as the default `pipeline_mod`, since the
  static pipeline lacks conversation support.
- **Duplicated substrate replaced with `defdelegate`**: `Artifacts`,
  `Components.FsmBreakpoint`, `Components.StepwiseContextMerge`, and
  `Components.StepwiseAction`.
- **Component hardening inherited from the engine**:
  - Wait short-circuit in `StepwiseAdvance` + `StepwiseEntryAction`:
    capabilities returning `{:wait, ...}` are honoured at all pipeline stages.
  - Transition-policy hook: `spec.transition_policy` can `:allow`,
    `{:redirect, state}`, or `{:deny, reason}` before every state move.
  - Projection-enricher hook: `spec.projection_enricher` can inject custom
    fields into `projection.extensions`.
  - `meta` passthrough: `runtime.meta` is included in capability input.
  - Init-error propagation: `init/2` returns
    `{:error, {:initial_entry_action_failed, reason, runtime}}` when the
    initial state's entry capability fails.
  - Telemetry spans on all lifecycle phases (`[:mobus_stepwise, :engine, *]`).

### Changed: Conversation completion (behaviour change)

`WorkflowStem.Components.StepwiseAction` no longer hardcodes domain-specific
field names in completion events. Completion payloads now merge transparently
into `runtime.context` with no interpretation. Consumers define their own
completion vocabulary in their `Adapters.ConversationHandler` implementation.
The test handler at `test/support/test_conversation_handler.ex` demonstrates
the generalized contract using `conversation_response`, `conversation_history`,
and `conversation_complete`.

### Removed

- `StepwiseEngine` no longer contains its own ALF orchestration, projection
  computation, or pipeline management — all delegated to the engine.
- `WorkflowStem.Capabilities` remains for direct consumer use but is no longer
  called internally.

## v0.1.0 (April 2026)

Initial public release: stepwise, FSM, and flow engines backed by ALF
pipelines, with spec → IR compilation and static (non-generated) pipelines.
