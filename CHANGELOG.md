# Changelog

## v0.2.0 (May 2026) — Foundation consolidation

### Added

- **Dependency on `mobus_stepwise`**: workflow_stem now depends on the foundation library
  (`fosferon/mobus_stepwise`). ~440 lines of duplicated substrate code eliminated via delegation.

- **WorkflowStem.Application**: Bridges workflow_stem's adapter config keys to mobus_stepwise's
  application env at startup (`:capability_runner_adapter`, `:capability_runner_strict`,
  `:conversation_handler`). Consumers configure `:workflow_stem` keys; the foundation engine
  sees `:mobus_stepwise` keys transparently.

- **`extensions` field** on `WorkflowStem.Projection` — structurally compatible with
  `Mobus.Stepwise.Projection`. `build_extensions/2` hook respects `spec.projection_enricher`.

### Changed

- **Engine delegates to foundation**: `WorkflowStem.Engines.StepwiseEngine` is now a thin shim
  over `Mobus.Stepwise.Engine`. All init/handle_event/restore calls delegate to the foundation;
  projection structs are converted (`Mobus.Stepwise.Projection` → `WorkflowStem.Projection`)
  on the way back. The shim injects `WorkflowStem.Pipelines.Stepwise` as the default
  `pipeline_mod` (the foundation's static pipeline lacks conversation support).

- **Duplicated substrate replaced with `defdelegate`**:
  - `WorkflowStem.Artifacts` → `Mobus.Stepwise.Artifacts`
  - `WorkflowStem.Components.FsmBreakpoint` → `Mobus.Stepwise.Components.FsmBreakpoint`
  - `WorkflowStem.Components.StepwiseContextMerge` → `Mobus.Stepwise.Components.StepwiseContextMerge`
  - `WorkflowStem.Components.StepwiseAction` → `Mobus.Stepwise.Components.StepwiseAction`

- **Component hardening inherited from foundation**:
  - **Wait short-circuit** in `StepwiseAdvance` + `StepwiseEntryAction`: capabilities returning
    `{:wait, ...}` are now properly honoured at all pipeline stages. Fixes bug where
    `{:wait, ...}` from entry capabilities was silently reprocessed.
  - **Transition-policy hook** in `StepwiseAdvance`: `spec.transition_policy` module can
    `:allow`, `{:redirect, state}`, or `{:deny, reason}` before every state move.
  - **Projection-enricher hook**: `spec.projection_enricher` module can inject custom fields
    into `projection.extensions`.
  - **Meta passthrough**: `runtime.meta` is now included in capability input (`input.meta`).
  - **Init-error propagation**: `init/2` now returns `{:error, {:initial_entry_action_failed,
    reason, runtime}}` when the initial state's entry capability fails. Previously this was
    silently swallowed.
  - **Telemetry spans** on all lifecycle phases (`[:mobus_stepwise, :engine, :init]`,
    `[:mobus_stepwise, :engine, :handle_event]`, `[:mobus_stepwise, :engine, :restore]`).

### Changed: Conversation completion (BREAKING for Atrapos)

`WorkflowStem.Components.StepwiseAction` no longer hardcodes Atrapos-specific field names
(`agent_response`, `chat_history`, `thinking`, `pre_research`, `next_event`). Completion
events merge their payload transparently into `runtime.context` with no interpretation.

**Atrapos migration recipe**: Update `Atrapos.Workflows.ConversationBridge` (the
`WorkflowStem.Adapters.ConversationHandler` implementation) so the `handle_conversation/5`
callback constructs whatever key names Atrapos's workflow specs expect. The old hardcoded
keys were:

| Old framework key      | Atrapos likely needs in spec |
|------------------------|------------------------------|
| `agent_response`       | Same, set by handler         |
| `chat_history`         | Same, managed by handler     |
| `thinking`             | Drop or set in handler       |
| `pre_research`         | Set as whatever key specs read|
| `next_event`           | Still honoured by StepwiseAdvance |

The test handler at `test/support/test_conversation_handler.ex` demonstrates the new pattern
using `conversation_response`, `conversation_history`, and `conversation_complete`.

### Removed

- `WorkflowStem.Engines.StepwiseEngine` no longer contains its own ALF orchestration,
  projection computation, or pipeline management — all delegated to foundation.
- `WorkflowStem.Capabilities` remains for direct consumer use but is no longer called
  internally (foundation uses `Mobus.Stepwise.Capabilities`).

## v0.1.0 (April 2026)

Initial extraction from MOBuS / Atrapos codebase per `STEM_EXTRACTION_PLAN.md`.
