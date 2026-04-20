defmodule WorkflowStem.ExecutionStoreTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.ExecutionStore

  setup do
    ExecutionStore.ensure_started()
    # Clean up any test entries
    on_exit(fn ->
      # Best effort cleanup
      try do
        ExecutionStore.delete("test-exec-1")
        ExecutionStore.delete("test-exec-2")
      rescue
        _ -> :ok
      end
    end)
    :ok
  end

  describe "put/1 and fetch/1" do
    test "stores and retrieves an entry" do
      entry = %{
        execution_id: "test-exec-1",
        tenant_id: "t1",
        workflow_handle: "test-flow",
        profile: :stepwise,
        runtime: %{current_state: :active}
      }

      :ok = ExecutionStore.put(entry)
      assert {:ok, ^entry} = ExecutionStore.fetch("test-exec-1")
    end

    test "returns not_found for missing execution" do
      assert {:error, :not_found} = ExecutionStore.fetch("nonexistent")
    end

    test "overwrites existing entry" do
      entry_v1 = %{
        execution_id: "test-exec-2",
        tenant_id: "t1",
        workflow_handle: "w1",
        profile: :fsm,
        runtime: %{current_state: :draft}
      }

      entry_v2 = %{entry_v1 | runtime: %{current_state: :submitted}}

      :ok = ExecutionStore.put(entry_v1)
      :ok = ExecutionStore.put(entry_v2)

      assert {:ok, fetched} = ExecutionStore.fetch("test-exec-2")
      assert fetched.runtime.current_state == :submitted
    end
  end

  describe "update/2" do
    test "updates an entry via function" do
      entry = %{
        execution_id: "test-exec-1",
        tenant_id: "t1",
        workflow_handle: "w1",
        profile: :stepwise,
        runtime: %{current_state: :step_1}
      }

      :ok = ExecutionStore.put(entry)

      assert {:ok, updated} = ExecutionStore.update("test-exec-1", fn e ->
        {:ok, put_in(e, [:runtime, :current_state], :step_2)}
      end)

      assert updated.runtime.current_state == :step_2
    end

    test "returns not_found for missing entry" do
      assert {:error, :not_found} = ExecutionStore.update("nonexistent", fn e -> {:ok, e} end)
    end

    test "propagates update function errors" do
      entry = %{
        execution_id: "test-exec-1",
        tenant_id: "t1",
        workflow_handle: "w1",
        profile: :stepwise,
        runtime: %{}
      }

      :ok = ExecutionStore.put(entry)

      assert {:error, :validation_failed} = ExecutionStore.update("test-exec-1", fn _e ->
        {:error, :validation_failed}
      end)
    end
  end

  describe "delete/1" do
    test "deletes an entry" do
      entry = %{
        execution_id: "test-exec-1",
        tenant_id: "t1",
        workflow_handle: "w1",
        profile: :stepwise,
        runtime: %{}
      }

      :ok = ExecutionStore.put(entry)
      :ok = ExecutionStore.delete("test-exec-1")
      assert {:error, :not_found} = ExecutionStore.fetch("test-exec-1")
    end
  end

  describe "list/1" do
    test "lists entries for a tenant" do
      entry1 = %{
        execution_id: "test-exec-1",
        tenant_id: "t1",
        workflow_handle: "w1",
        profile: :stepwise,
        runtime: %{}
      }

      entry2 = %{
        execution_id: "test-exec-2",
        tenant_id: "t2",
        workflow_handle: "w1",
        profile: :stepwise,
        runtime: %{}
      }

      :ok = ExecutionStore.put(entry1)
      :ok = ExecutionStore.put(entry2)

      t1_entries = ExecutionStore.list("t1")
      assert length(t1_entries) >= 1
      assert Enum.any?(t1_entries, &(&1.execution_id == "test-exec-1"))
      refute Enum.any?(t1_entries, &(&1.execution_id == "test-exec-2"))
    end
  end
end
