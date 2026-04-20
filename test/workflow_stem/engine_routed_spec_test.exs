defmodule WorkflowStem.EngineRoutedSpecTest do
  @moduledoc """
  End-to-end proof that a routed spec actually executes its declared
  ALF branches when driven through `WorkflowStem.Engines.StepwiseEngine`
  via `WorkflowStem.Registry.ensure_instance/3`.

  This is the "full flexibility" integration: load an agent, get a
  workflow compiled from its spec, run it through the engine — the
  routed state's branch stages fire, the state machine transitions, and
  the projection reflects the new state.
  """

  use ExUnit.Case, async: false

  alias WorkflowStem.Engines.StepwiseEngine
  alias WorkflowStem.IR
  alias WorkflowStem.Registry

  # ── Test stage: tags the runtime context with which branch ran ─────

  defmodule BranchTagger do
    @doc """
    ALF stage used inside a switch branch. Pulls `:tag` from opts and
    writes it into the event's runtime context so the test can assert
    which branch was taken.
    """
    def call(event, opts) do
      # Respect the projection pass — it runs the same pipeline and
      # must not pollute the real-event result.
      if Map.get(event, :skip_transition, false) do
        event
      else
        tag = Keyword.fetch!(opts, :tag)
        runtime = event.runtime
        context = Map.put(runtime.context || %{}, :last_branch_tag, tag)
        %{event | runtime: %{runtime | context: context}}
      end
    end
  end

  # ── Switch resolver ────────────────────────────────────────────────

  defmodule PickRouter do
    @doc "Picks the branch based on the payload's :choose field."
    def pick(event, _opts) do
      Map.get(event.payload || %{}, :choose, :a)
    end
  end

  defp spec do
    IR.normalize(%{
      id: "engine-routed-test",
      profile: :stepwise,
      initial_state: :triage,
      states: %{
        triage: %{
          route:
            {:switch, :pick,
             %{
               a: [{:stage, BranchTagger, opts: [tag: :branch_a]}],
               b: [{:stage, BranchTagger, opts: [tag: :branch_b]}]
             }}
        }
      },
      transitions: %{},
      routing: %{pick: {PickRouter, :pick}}
    })
  end

  setup do
    on_exit(fn ->
      Registry.release_instance("agent-x", "engine-routed-test")
    end)

    :ok
  end

  test "engine.init + handle_event routes through the declared branch (end-to-end)" do
    # 1. Compile a per-agent pipeline for a routed spec.
    {:ok, pipeline_mod} =
      Registry.ensure_instance("agent-x", "engine-routed-test", spec())

    # Sanity: the compiled module is NOT the shared static pipeline —
    # routed specs get their own topology.
    refute pipeline_mod == WorkflowStem.Pipelines.Stepwise

    # 2. Drive the engine with the injected pipeline.
    runtime_context = %{
      tenant_id: "agent-x",
      execution_id: "exec-1",
      pipeline_mod: pipeline_mod,
      sync: true,
      initial_context: %{}
    }

    {:ok, runtime} = StepwiseEngine.init(spec(), runtime_context)

    # 3. Send an event that should route to branch :a.
    {:ok, runtime_a} =
      StepwiseEngine.handle_event(runtime, :chat_message, %{choose: :a})

    assert runtime_a.context[:last_branch_tag] == :branch_a

    # 4. Send an event that should route to branch :b.
    {:ok, runtime_b} =
      StepwiseEngine.handle_event(runtime_a, :chat_message, %{choose: :b})

    assert runtime_b.context[:last_branch_tag] == :branch_b
  end

  test "engine defaults to the shared static pipeline when no pipeline_mod is injected" do
    # Unrouted spec → Registry returns the shared static pipeline.
    unrouted =
      IR.normalize(%{
        id: "engine-unrouted-test",
        profile: :stepwise,
        initial_state: :a,
        states: %{a: %{action: %{type: :noop}}}
      })

    {:ok, pipeline_mod} =
      Registry.ensure_instance("agent-x", "engine-unrouted-test", unrouted)

    assert pipeline_mod == WorkflowStem.Pipelines.Stepwise

    # Passing no :pipeline_mod at all should also work — engine falls
    # back to the shared static pipeline.
    {:ok, runtime} =
      StepwiseEngine.init(unrouted, %{
        tenant_id: "agent-x",
        execution_id: "exec-2",
        sync: true,
        initial_context: %{}
      })

    assert runtime.pipeline_mod == WorkflowStem.Pipelines.Stepwise
  end
end
