defmodule WorkflowStem.RegistryInstanceTest do
  @moduledoc """
  Exercises the per-agent pipeline instance cache on `WorkflowStem.Registry`.

  The existing spec-discovery behaviour is unchanged and covered elsewhere;
  these tests target `ensure_instance/2` / `instance_module/2` /
  `release_instance/2`.
  """

  use ExUnit.Case, async: false

  alias WorkflowStem.{IR, Registry}

  # Passthrough stage module — needs to be a real, loaded module.
  defmodule PassThrough do
    def call(event, _opts), do: event
  end

  defmodule Routers do
    def pick_branch(event, _opts) do
      case Map.get(event, :choose) do
        :y -> :y
        _ -> :x
      end
    end
  end

  defp routed_spec do
    IR.normalize(%{
      id: "registry-test-routed",
      profile: :stepwise,
      initial_state: :a,
      states: %{
        a: %{
          route:
            {:switch, :pick_branch,
             %{
               x: [{:stage, PassThrough}],
               y: [{:stage, PassThrough}]
             }}
        }
      },
      routing: %{pick_branch: {Routers, :pick_branch}}
    })
  end

  defp static_spec do
    IR.normalize(%{
      id: "registry-test-static",
      profile: :stepwise,
      initial_state: :a,
      states: %{a: %{action: %{type: :noop}}}
    })
  end

  setup do
    on_exit(fn ->
      Registry.release_instance("agent-a", "registry-test-routed")
      Registry.release_instance("agent-b", "registry-test-routed")
      Registry.release_instance("agent-a", "registry-test-static")
    end)

    :ok
  end

  describe "ensure_instance/2 — routed specs" do
    test "compiles and returns a per-agent module on first call" do
      assert {:ok, mod} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      assert is_atom(mod)
      assert to_string(mod) =~ "WorkflowStem.Generated.agent_a.registry_test_routed"
      assert Registry.instance_module("agent-a", "registry-test-routed") == mod
    end

    test "returns the same cached module on repeat calls" do
      {:ok, mod1} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      {:ok, mod2} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())

      assert mod1 == mod2
    end

    test "different agent_ids get different compiled modules" do
      {:ok, mod_a} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      {:ok, mod_b} = Registry.ensure_instance("agent-b", "registry-test-routed", routed_spec())

      refute mod_a == mod_b
    end

    test "the compiled module actually runs and routes through ALF" do
      {:ok, mod} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())

      # The module is already started by ensure_instance — just call it.
      result_x = mod.call(%{choose: :x})
      result_y = mod.call(%{choose: :y})

      # Both branches in this test spec are passthroughs; the event returns
      # unchanged. What matters is ALF didn't error — meaning the switch
      # resolver (defdelegate) was callable and returned a valid branch key.
      assert result_x.choose == :x
      assert result_y.choose == :y
    end

    test "returns {:error, {:unknown_workflow, handle}} for a missing spec" do
      # This path exercises the 2-arity form which goes through spec_module_for/1.
      assert {:error, {:unknown_workflow, "does-not-exist"}} =
               Registry.ensure_instance("agent-a", "does-not-exist")
    end
  end

  describe "ensure_instance/3 — static specs (no routes)" do
    test "falls through to the shared static Stepwise pipeline" do
      {:ok, mod} = Registry.ensure_instance("agent-a", "registry-test-static", static_spec())
      assert mod == WorkflowStem.Pipelines.Stepwise

      # No per-agent cache entry created
      assert Registry.instance_module("agent-a", "registry-test-static") == nil
    end
  end

  describe "release_instance/2" do
    test "stops the module and clears the cache" do
      {:ok, mod} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      assert Registry.instance_module("agent-a", "registry-test-routed") == mod

      :ok = Registry.release_instance("agent-a", "registry-test-routed")
      assert Registry.instance_module("agent-a", "registry-test-routed") == nil
    end

    test "is a no-op when no instance has been compiled" do
      assert Registry.release_instance("never-compiled", "registry-test-routed") == :ok
    end

    test "after release, ensure_instance recompiles and caches again" do
      {:ok, mod1} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      :ok = Registry.release_instance("agent-a", "registry-test-routed")

      {:ok, mod2} = Registry.ensure_instance("agent-a", "registry-test-routed", routed_spec())
      # Same module name, but freshly re-compiled — the generated name is
      # derived from agent_id + handle, so it's stable across release/recompile.
      assert mod1 == mod2
    end
  end
end
