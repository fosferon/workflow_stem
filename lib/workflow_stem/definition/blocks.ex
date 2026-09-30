defmodule WorkflowStem.Definition.Blocks do
  @moduledoc """
  Runs the block a node names.

  A host's capability runner calls `execute/4` with its registry of blocks
  (`%{handle => module}`). A handle that is not a block returns
  `:unregistered`, so the host can fall through to whatever else it runs.

  Two blocks come with the library: `stem.wait` (pause, optionally until a
  deadline) and `stem.set` (put values into the run's context).
  """

  alias WorkflowStem.Definition.Template

  @builtin %{
    "stem.wait" => __MODULE__.Wait,
    "stem.set" => __MODULE__.Set
  }

  @doc "The library's own blocks."
  @spec builtin() :: %{String.t() => module()}
  def builtin, do: @builtin

  @spec execute(%{String.t() => module()}, term(), String.t() | atom(), map()) ::
          {:ok, map()} | {:wait, map()} | {:error, term()} | :unregistered
  def execute(registry, tenant_id, handle, input) when is_map(registry) and is_map(input) do
    case Map.get(@builtin, to_string(handle)) || Map.get(registry, to_string(handle)) do
      nil -> :unregistered
      block -> run(block, tenant_id, input)
    end
  end

  defp run(block, tenant_id, input) do
    config = Map.get(input, :action_config) || %{}
    node = Map.get(config, "node")
    context = Map.get(input, :context) || %{}

    env = %{
      tenant_id: tenant_id,
      node: node,
      execution_id: Map.get(input, :execution_id),
      context: context,
      params: Map.get(context, "params") || %{},
      meta: Map.get(input, :meta) || %{},
      token_id: Map.get(input, :token_id),
      branch_id: Map.get(input, :branch_id)
    }

    with {:ok, arguments} <- Template.render(Map.get(config, "with") || %{}, context) do
      case block.run(arguments, env) do
        {:ok, value} when is_binary(node) -> {:ok, %{context: %{node => value}}}
        {:ok, _value} -> {:ok, %{context: %{}}}
        {:merge, %{} = updates} -> {:ok, %{context: updates}}
        {:wait, %{} = wait} -> {:wait, %{wait: wait}}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_block_result, other}}
      end
    end
  end

  defmodule Wait do
    @moduledoc """
    Pauses the branch until it is resumed from outside.

    Arguments: `reason`, and at most one of `deadline_at` (ISO 8601),
    `deadline_minutes`, `deadline_seconds`. With a deadline, the node's
    `on: timeout` edge is followed when it passes.
    """

    @behaviour WorkflowStem.Definition.Block

    @impl true
    def handle, do: "stem.wait"

    @impl true
    def describe do
      %{
        label: "Wait",
        description: "Pause until resumed, or until a deadline passes.",
        arguments: [
          %{name: "reason", type: "string"},
          %{name: "deadline_minutes", type: "integer"},
          %{name: "deadline_at", type: "string"}
        ]
      }
    end

    @impl true
    def run(arguments, _env) do
      wait = %{reason: Map.get(arguments, "reason") || "waiting"}

      case deadline(arguments) do
        {:ok, nil} -> {:wait, wait}
        {:ok, deadline} -> {:wait, Map.put(wait, :deadline, deadline)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp deadline(%{"deadline_at" => at}) when is_binary(at) do
      case DateTime.from_iso8601(at) do
        {:ok, deadline, _offset} -> {:ok, deadline}
        _ -> {:error, {:invalid_deadline, at}}
      end
    end

    defp deadline(%{"deadline_minutes" => minutes}) when is_number(minutes),
      do: {:ok, DateTime.add(DateTime.utc_now(), round(minutes * 60), :second)}

    defp deadline(%{"deadline_seconds" => seconds}) when is_number(seconds),
      do: {:ok, DateTime.add(DateTime.utc_now(), round(seconds), :second)}

    defp deadline(_arguments), do: {:ok, nil}
  end

  defmodule Set do
    @moduledoc "Puts its arguments into the run's context, as they are."

    @behaviour WorkflowStem.Definition.Block

    @impl true
    def handle, do: "stem.set"

    @impl true
    def describe, do: %{label: "Set values", description: "Put values into the run's data."}

    @impl true
    def run(arguments, _env), do: {:merge, arguments}
  end
end
