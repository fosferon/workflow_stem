defmodule WorkflowStem.PersistenceTest do
  # Changes application env, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias WorkflowStem.Persistence

  defmodule StubAdapter do
    def save_execution(_tenant_id, execution), do: {:ok, execution}
  end

  setup do
    previous = Application.get_env(:workflow_stem, :persistence_adapter)
    on_exit(fn -> Application.put_env(:workflow_stem, :persistence_adapter, previous) end)
    :ok
  end

  defp use_adapter(mod), do: Application.put_env(:workflow_stem, :persistence_adapter, mod)

  describe "enabled?/0" do
    test "is false with no adapter" do
      use_adapter(nil)
      refute Persistence.enabled?()
    end

    test "is false for a module that cannot be loaded" do
      use_adapter(DoesNotExist.Adapter)
      refute Persistence.enabled?()
    end

    test "is false for a loaded module without save_execution/2" do
      use_adapter(String)
      refute Persistence.enabled?()
    end

    test "is false for the behaviour module itself" do
      use_adapter(WorkflowStem.Adapters.PersistenceAdapter)
      refute Persistence.enabled?()
    end

    test "is true for a module exporting save_execution/2" do
      use_adapter(StubAdapter)
      assert Persistence.enabled?()
    end
  end

  describe "with persistence disabled" do
    setup do
      use_adapter(nil)
      :ok
    end

    test "writes are skipped" do
      assert Persistence.save_execution("t1", %{id: "e1"}) == {:ok, :skipped}
      assert Persistence.save_checkpoint("t1", "e1", %{}) == {:ok, :skipped}
    end

    test "get_execution/2 reports persistence disabled" do
      assert Persistence.get_execution("t1", "e1") == {:error, :persistence_disabled}
    end

    test "list_executions/2 returns an empty list" do
      assert Persistence.list_executions("t1", %{}) == {:ok, []}
    end
  end

  test "a configured adapter receives the call" do
    use_adapter(StubAdapter)
    assert Persistence.save_execution("t1", %{id: "e1"}) == {:ok, %{id: "e1"}}
  end
end
