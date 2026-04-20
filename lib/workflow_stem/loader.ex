defmodule WorkflowStem.Loader do
  @moduledoc """
  Loads and compiles workflow specs (maps) into an internal IR (data).

  This does not generate Elixir modules. For UI-authored workflows loaded from disk,
  the stem interprets the IR using static profile pipelines.
  """

  alias WorkflowStem.Cache
  alias WorkflowStem.Types

  @spec get_or_compile(Types.tenant_id(), Types.workflow_handle(), map()) ::
          {:ok, Types.ir()} | {:error, term()}
  def get_or_compile(tenant_id, workflow_handle, %{artifact_hash: artifact_hash} = artifact) do
    key = {tenant_id, workflow_handle, artifact_hash}

    case Cache.get(key) do
      {:ok, ir} ->
        {:ok, ir}

      :miss ->
        with {:ok, spec} <- load_from_artifact(tenant_id, workflow_handle, artifact),
             :ok <- validate_spec(spec),
             {:ok, ir} <- compile_to_ir(spec) do
          :ok = Cache.put(key, ir)
          {:ok, ir}
        end
    end
  end

  def get_or_compile(_tenant_id, _workflow_handle, _artifact),
    do: {:error, :missing_artifact_hash}

  @spec load_from_artifact(Types.tenant_id(), Types.workflow_handle(), map()) ::
          {:ok, Types.spec()} | {:error, term()}
  def load_from_artifact(_tenant_id, _workflow_handle, %{spec: %{} = spec}),
    do: {:ok, spec}

  def load_from_artifact(_tenant_id, _workflow_handle, _artifact),
    do: {:error, :invalid_artifact}

  @spec validate_spec(Types.spec()) :: :ok | {:error, term()}
  def validate_spec(%{} = spec) do
    profile = Map.get(spec, :profile) || Map.get(spec, "profile")

    case profile do
      :flow -> :ok
      :fsm -> :ok
      :stepwise -> :ok
      "flow" -> :ok
      "fsm" -> :ok
      "stepwise" -> :ok
      nil -> {:error, :missing_profile}
      other -> {:error, {:invalid_profile, other}}
    end
  end

  @spec compile_to_ir(Types.spec()) :: {:ok, Types.ir()} | {:error, term()}
  def compile_to_ir(%{} = spec) do
    # Phase-2 implementation will normalize and precompute:
    # - state/event vocab
    # - transition table
    # - ui projection indices
    #
    ir = WorkflowStem.IR.normalize(spec) |> Map.put(:__compiled__, true)
    {:ok, ir}
  end
end
