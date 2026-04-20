defmodule WorkflowStem.ArtifactsTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.Artifacts

  describe "normalize/1" do
    test "returns empty map for nil" do
      assert %{} = Artifacts.normalize(nil)
    end

    test "normalizes raw value into opaque entry" do
      result = Artifacts.normalize(%{"my_key" => "raw_value"})
      assert %{"my_key" => entry} = result
      assert entry["kind"] == "opaque"
      assert entry["version"] == 1
      assert entry["data"] == "raw_value"
      assert entry["inserted_at"] != nil
    end

    test "normalizes structured entry" do
      result = Artifacts.normalize(%{
        "report" => %{kind: "pdf", version: 2, data: %{url: "http://example.com"}}
      })

      assert %{"report" => entry} = result
      assert entry["kind"] == "pdf"
      assert entry["version"] == 2
      assert entry["data"] == %{url: "http://example.com"}
    end

    test "preserves meta field" do
      result = Artifacts.normalize(%{
        "doc" => %{kind: "doc", data: "content", meta: %{source: "upload"}}
      })

      assert %{"doc" => entry} = result
      assert entry["meta"] == %{source: "upload"}
    end

    test "returns empty map for non-map input" do
      assert %{} = Artifacts.normalize("invalid")
    end
  end

  describe "merge/2" do
    test "merges two artifact maps" do
      existing = %{"a" => %{kind: "type1", data: "old"}}
      incoming = %{"b" => %{kind: "type2", data: "new"}}

      result = Artifacts.merge(existing, incoming)
      assert Map.has_key?(result, "a")
      assert Map.has_key?(result, "b")
    end

    test "incoming overwrites existing key" do
      existing = %{"a" => %{kind: "v1", data: "old"}}
      incoming = %{"a" => %{kind: "v2", data: "new"}}

      result = Artifacts.merge(existing, incoming)
      assert result["a"]["kind"] == "v2"
    end

    test "handles nil inputs" do
      assert %{} = Artifacts.merge(nil, nil)
      assert %{} = Artifacts.merge(%{}, nil)
      assert %{} = Artifacts.merge(nil, %{})
    end
  end
end
