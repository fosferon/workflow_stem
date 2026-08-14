defmodule WorkflowStem.Pipeline.BuilderTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.{Compiler, IR}
  alias WorkflowStem.Pipeline.Builder

  # ── Test support: a simple passthrough stage module ─────────────────

  defmodule Passthrough do
    def call(event, _opts), do: event
  end

  defmodule TagStage do
    # Appends its name to the event's :tags list
    def call(event, opts) do
      tag = Keyword.fetch!(opts, :tag)
      Map.update(event, :tags, [tag], &(&1 ++ [tag]))
    end
  end

  defmodule Routers do
    # Classic switch resolver — returns a branch key
    def triage_route(event, _opts) do
      case Map.get(event, :strategy) do
        :deep -> :deep
        _ -> :simple
      end
    end
  end

  # Each test generates a unique module name so runs don't collide.
  defp unique_module(suffix) do
    id = System.unique_integer([:positive, :monotonic])
    Module.concat(["WorkflowStemTest", "Gen#{id}", suffix])
  end

  describe "build/3 — stage-only pipelines" do
    test "compiles a single-stage passthrough pipeline that runs" do
      spec =
        IR.normalize(%{
          profile: :stepwise,
          initial_state: :a,
          states: %{a: %{route: {:stage, TagStage, opts: [tag: :hit]}}},
          routing: %{}
        })

      descriptors = Compiler.components_for(spec)
      mod = unique_module("StagePipeline")

      {:ok, ^mod} = Builder.build(mod, descriptors, %{})

      try do
        :ok = mod.start()
        assert mod.call(%{tags: []}) == %{tags: [:hit]}
      after
        mod.stop()
      end
    end

    test "compiles a multi-stage linear pipeline" do
      spec =
        IR.normalize(%{
          profile: :stepwise,
          initial_state: :a,
          states: %{
            a: %{
              route: [
                {:stage, TagStage, opts: [tag: :one]},
                {:stage, TagStage, opts: [tag: :two]}
              ]
            }
          },
          routing: %{}
        })

      descriptors = Compiler.components_for(spec)
      mod = unique_module("MultiStage")

      {:ok, ^mod} = Builder.build(mod, descriptors, %{})

      try do
        :ok = mod.start()
        assert mod.call(%{tags: []}) == %{tags: [:one, :two]}
      after
        mod.stop()
      end
    end
  end

  describe "build/3 — switch routing" do
    test "routes to :simple or :deep branch based on the resolver" do
      spec =
        IR.normalize(%{
          profile: :stepwise,
          initial_state: :a,
          states: %{
            a: %{
              route:
                {:switch, :triage_route,
                 %{
                   simple: [{:stage, TagStage, opts: [tag: :simple_branch]}],
                   deep: [{:stage, TagStage, opts: [tag: :deep_branch]}]
                 }}
            }
          },
          routing: %{triage_route: {Routers, :triage_route}}
        })

      descriptors = Compiler.components_for(spec)
      mod = unique_module("SwitchPipeline")

      {:ok, ^mod} = Builder.build(mod, descriptors, spec.routing)

      try do
        :ok = mod.start()

        simple_result = mod.call(%{strategy: :passthrough, tags: []})
        assert simple_result.tags == [:simple_branch]

        deep_result = mod.call(%{strategy: :deep, tags: []})
        assert deep_result.tags == [:deep_branch]
      after
        mod.stop()
      end
    end

    test "the generated module exposes routing names as delegated functions" do
      routing = %{triage_route: {Routers, :triage_route}}

      spec =
        IR.normalize(%{
          profile: :stepwise,
          initial_state: :a,
          states: %{
            a: %{
              route:
                {:switch, :triage_route,
                 %{simple: [{:stage, Passthrough}], deep: [{:stage, Passthrough}]}}
            }
          },
          routing: routing
        })

      mod = unique_module("DelegateCheck")
      {:ok, ^mod} = Builder.build(mod, Compiler.components_for(spec), routing)

      # The routing function is directly callable on the generated module,
      # proving the defdelegate landed.
      assert mod.triage_route(%{strategy: :deep}, []) == :deep
      assert mod.triage_route(%{strategy: :anything_else}, []) == :simple
    end
  end

  describe "build/3 — tbd placeholder" do
    test "a :tbd-only pipeline compiles" do
      spec =
        IR.normalize(%{
          profile: :stepwise,
          initial_state: :a,
          states: %{a: %{route: {:tbd, :not_yet}}},
          routing: %{}
        })

      descriptors = Compiler.components_for(spec)
      mod = unique_module("TbdPipeline")

      {:ok, ^mod} = Builder.build(mod, descriptors, %{})
    end
  end

  describe "build/3 — plug_with" do
    test "compiles a plug scope with a recursively emitted body" do
      descriptors = [
        {:plug_with, SomeMod,
         %{
           state: :a,
           count: 1,
           opts: [],
           body: [{:tbd, :inside, %{state: :a, count: 1, opts: []}}]
         }}
      ]

      mod = unique_module("PlugWithPipeline")
      assert {:ok, ^mod} = Builder.build(mod, descriptors, %{})
    end

    test "compiles nested plug scopes containing a switch" do
      descriptors = [
        {:plug_with, SomeMod,
         %{
           state: :a,
           count: 1,
           opts: [],
           body: [
             {:plug_with, NestedMod,
              %{
                state: :a,
                count: 1,
                opts: [],
                body: [
                  {:switch, :triage_route,
                   %{
                     state: :a,
                     count: 1,
                     opts: [],
                     resolver: {Routers, :triage_route},
                     branches: %{
                       simple: [{:tbd, :simple, %{state: :a, count: 1, opts: []}}],
                       deep: [{:tbd, :deep, %{state: :a, count: 1, opts: []}}]
                     }
                   }}
                ]
              }}
           ]
         }}
      ]

      mod = unique_module("NestedPlugWithPipeline")

      assert {:ok, ^mod} =
               Builder.build(mod, descriptors, %{triage_route: {Routers, :triage_route}})
    end
  end
end
