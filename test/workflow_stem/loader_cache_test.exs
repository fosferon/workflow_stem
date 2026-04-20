defmodule WorkflowStem.LoaderCacheTest do
  use ExUnit.Case, async: false

  alias WorkflowStem.{Loader, Cache, CacheOwner}

  setup do
    CacheOwner.ensure_started()
    # Clear cache for isolation
    :ets.match_delete(WorkflowStem.Cache, {{:_, :_, :_}, :_})
    :ok
  end

  describe "Loader.get_or_compile/3" do
    test "returns error when artifact_hash is missing" do
      assert {:error, :missing_artifact_hash} =
               Loader.get_or_compile("t1", "w1", %{spec: %{}})
    end

    test "returns error when artifact has no spec" do
      assert {:error, :invalid_artifact} =
               Loader.get_or_compile("t1", "w1", %{artifact_hash: "abc123"})
    end

    test "returns error for invalid profile" do
      assert {:error, :missing_profile} =
               Loader.get_or_compile("t1", "w1", %{
                 artifact_hash: "abc",
                 spec: %{states: %{}}
               })
    end

    test "compiles and caches a valid stepwise spec" do
      spec = %{profile: :stepwise, initial_state: :start, states: %{}}
      artifact = %{artifact_hash: "hash1", spec: spec}

      assert {:ok, ir} = Loader.get_or_compile("t1", "w1", artifact)
      assert ir.profile == :stepwise
      assert ir.__compiled__ == true

      # Second call should hit cache
      assert {:ok, ir2} = Loader.get_or_compile("t1", "w1", artifact)
      assert ir2 == ir
    end

    test "compiles and caches a valid fsm spec" do
      spec = %{profile: :fsm, initial_state: :idle, states: %{}}
      artifact = %{artifact_hash: "fsm-hash", spec: spec}

      assert {:ok, ir} = Loader.get_or_compile("t1", "w1", artifact)
      assert ir.profile == :fsm
    end

    test "different tenant/handle gets separate cache entry" do
      spec = %{profile: :stepwise, initial_state: :start, states: %{}}

      {:ok, _} = Loader.get_or_compile("t1", "w1", %{artifact_hash: "h1", spec: spec})
      {:ok, _} = Loader.get_or_compile("t2", "w1", %{artifact_hash: "h1", spec: spec})

      # Both should be cached independently
      assert {:ok, _} = Cache.get({"t1", "w1", "h1"})
      assert {:ok, _} = Cache.get({"t2", "w1", "h1"})
    end
  end

  describe "Cache" do
    test "get returns :miss for non-existent key" do
      assert :miss = Cache.get({"nonexistent", "w", "h"})
    end

    test "put and get roundtrip" do
      key = {"t1", "w1", "hash1"}
      ir = %{profile: :stepwise, __compiled__: true}

      :ok = Cache.put(key, ir)
      assert {:ok, ^ir} = Cache.get(key)
    end

    test "invalidate removes entries for a tenant/handle pair" do
      :ok = Cache.put({"t1", "w1", "h1"}, %{a: 1})
      :ok = Cache.put({"t1", "w1", "h2"}, %{a: 2})
      :ok = Cache.put({"t1", "w2", "h1"}, %{a: 3})

      Cache.invalidate("t1", "w1")

      assert :miss = Cache.get({"t1", "w1", "h1"})
      assert :miss = Cache.get({"t1", "w1", "h2"})
      # Different handle unaffected
      assert {:ok, _} = Cache.get({"t1", "w2", "h1"})
    end
  end

  describe "Loader.validate_spec/1" do
    test "accepts stepwise profile" do
      assert :ok = Loader.validate_spec(%{profile: :stepwise})
    end

    test "accepts fsm profile" do
      assert :ok = Loader.validate_spec(%{profile: :fsm})
    end

    test "accepts flow profile" do
      assert :ok = Loader.validate_spec(%{profile: :flow})
    end

    test "rejects missing profile" do
      assert {:error, :missing_profile} = Loader.validate_spec(%{})
    end

    test "rejects invalid profile" do
      assert {:error, {:invalid_profile, :bogus}} = Loader.validate_spec(%{profile: :bogus})
    end
  end
end
