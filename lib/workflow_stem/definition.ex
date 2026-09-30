defmodule WorkflowStem.Definition do
  @moduledoc """
  A workflow written as data.

  A definition is a plain map — what a designer saves, what a seed file
  holds, what a database row stores:

      %{
        "name" => "reservation_sync",
        "inputs" => %{"lookback_days" => %{"type" => "integer", "default" => 2}},
        "start" => "search",
        "nodes" => %{
          "search" => %{"action" => "data_source.call", "with" => %{"operation" => "reservation_search"}},
          "each" => %{"type" => "for_each", "over" => "{{search.ids}}", "collect" => "save.outcome"},
          "fetch" => %{"action" => "data_source.call", "with" => %{"id" => "{{item}}"}},
          "save" => %{"action" => "records.save", "with" => %{"from" => "{{fetch}}"}},
          "saved" => %{"type" => "join"},
          "done" => %{"type" => "end"}
        },
        "edges" => [["search", "each"], ["each", "fetch"], ["fetch", "save"], ["save", "saved"], ["saved", "done"]]
      }

  A node is one of:

    * an action — `"action"` names a block (`WorkflowStem.Definition.Block`),
      `"with"` gives its arguments
    * `"wait"` — pause until resumed; arguments as `Blocks.Wait`
    * `"set"` — put values into the run's data
    * `"type"` — `fork`, `join`, `end`, or `for_each`
    * empty — a point where edges meet or a decision is taken

  Edges are `[from, to]` or a map with `from`, `to` and optionally `when`
  (a `Mobus.Stepwise.Condition`), `on: "timeout"`, `branch_id`.

  `compile/1` turns a definition into a `mobus_stepwise` graph spec. Nothing
  in a definition becomes an atom.
  """

  alias Mobus.Stepwise.Engine
  alias WorkflowStem.Definition.{Inputs, Template}

  @max_nodes 512
  @node_id ~r/\A[A-Za-z][A-Za-z0-9_]*\z/
  @reserved ~w(params item trigger run flow_results)
  @structural ~w(fork join end for_each)
  @kinds ~w(action wait set type)

  @type t :: %{optional(String.t()) => term()}

  @doc "Compiles a definition into a graph spec, or says what is wrong with it."
  @spec compile(term()) :: {:ok, map()} | {:error, term()}
  def compile(definition) do
    with {:ok, definition} <- normalize(definition),
         {:ok, name} <- fetch_name(definition),
         nodes = Map.get(definition, "nodes"),
         :ok <- validate_nodes(nodes),
         {:ok, start} <- fetch_start(definition, nodes),
         :ok <- inputs_ok(Map.get(definition, "inputs")),
         {:ok, compiled_nodes} <- compile_nodes(nodes),
         {:ok, edges} <- compile_edges(Map.get(definition, "edges") || [], nodes) do
      spec = %{
        "profile" => "flow",
        "initial_state" => start,
        "nodes" => compiled_nodes,
        "edges" => edges,
        "metadata" => %{"name" => name, "inputs" => Map.get(definition, "inputs") || %{}}
      }

      check_with_engine(spec)
    end
  end

  @doc "`:ok` when the definition compiles."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(definition) do
    with {:ok, _spec} <- compile(definition), do: :ok
  end

  @doc "A stable fingerprint of a definition: the same content gives the same hash."
  @spec hash(map()) :: String.t()
  def hash(definition) do
    {:ok, definition} = normalize(definition)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical(definition)))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The definition with every map key a string. Atom keys (a definition
  written in code) are accepted; any other key type is refused.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%{} = definition) do
    {:ok, stringify(definition)}
  catch
    {:invalid_key, key} -> {:error, {:invalid_key, key}}
  end

  def normalize(_definition), do: {:error, :definition_not_a_map}

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {key, stringify(value)}

      {key, value} when is_atom(key) and not is_nil(key) ->
        {Atom.to_string(key), stringify(value)}

      {key, _value} ->
        throw({:invalid_key, key})
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp canonical(%{} = map),
    do: map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp fetch_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp fetch_name(_definition), do: {:error, :missing_name}

  defp validate_nodes(%{} = nodes) when map_size(nodes) == 0, do: {:error, :no_nodes}

  defp validate_nodes(%{} = nodes) when map_size(nodes) > @max_nodes,
    do: {:error, {:too_many_nodes, map_size(nodes), @max_nodes}}

  defp validate_nodes(%{} = nodes) do
    Enum.find_value(nodes, :ok, fn {id, node} ->
      cond do
        not Regex.match?(@node_id, id) -> {:error, {:invalid_node_id, id}}
        id in @reserved -> {:error, {:reserved_node_id, id}}
        not is_map(node) -> {:error, {:invalid_node, id, :not_a_map}}
        true -> nil
      end
    end)
  end

  defp validate_nodes(_nodes), do: {:error, :no_nodes}

  defp fetch_start(%{"start" => start}, nodes) when is_binary(start) do
    if Map.has_key?(nodes, start), do: {:ok, start}, else: {:error, {:unknown_start, start}}
  end

  defp fetch_start(_definition, _nodes), do: {:error, :missing_start}

  defp inputs_ok(inputs) do
    case Inputs.validate(inputs) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_inputs, errors}}
    end
  end

  defp compile_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {id, node}, {:ok, acc} ->
      case compile_node(id, node) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, id, with_meta(compiled, node))}}
        {:error, reason} -> {:halt, {:error, {:invalid_node, id, reason}}}
      end
    end)
  end

  defp compile_node(id, node) do
    case Enum.filter(@kinds, &Map.has_key?(node, &1)) do
      [] -> {:ok, %{}}
      ["action"] -> action_node(id, Map.get(node, "action"), Map.get(node, "with"))
      ["wait"] -> action_node(id, "stem.wait", Map.get(node, "wait"))
      ["set"] -> action_node(id, "stem.set", Map.get(node, "set"))
      ["type"] -> structural_node(node)
      several -> {:error, {:more_than_one_kind, several}}
    end
  end

  defp action_node(id, handle, arguments)
       when is_binary(handle) and handle != "" and (is_map(arguments) or is_nil(arguments)) do
    {:ok,
     %{
       "action" => %{
         "type" => "capability",
         "handle" => handle,
         "config" => %{"node" => id, "with" => arguments || %{}}
       }
     }}
  end

  defp action_node(_id, handle, _arguments) when not is_binary(handle) or handle == "",
    do: {:error, :action_not_a_handle}

  defp action_node(_id, _handle, _arguments), do: {:error, :arguments_not_a_map}

  defp structural_node(%{"type" => "for_each"} = node) do
    with {:ok, over} <- for_each_over(Map.get(node, "over")) do
      {:ok,
       node
       |> Map.take(~w(type as max_concurrency on_error))
       |> Map.put("over", over)
       |> put_path("collect", Map.get(node, "collect"))}
    end
  end

  defp structural_node(%{"type" => type} = node) when type in @structural,
    do: {:ok, Map.take(node, ~w(type join_policy failure_policy expected_branches))}

  defp structural_node(%{"type" => type}), do: {:error, {:unknown_type, type}}

  # `over` and `collect` name a place in the run's data. They may be written
  # as a reference (`{{search.ids}}`) like everything else, or as a bare path.
  defp for_each_over(over) when is_list(over), do: {:ok, over}
  defp for_each_over(over) when is_binary(over) and over != "", do: {:ok, path(over)}
  defp for_each_over(_over), do: {:error, :for_each_needs_over}

  defp put_path(node, _key, nil), do: node
  defp put_path(node, key, value) when is_binary(value), do: Map.put(node, key, path(value))
  defp put_path(node, _key, _value), do: node

  defp path(value), do: Template.reference_path(value) || value

  # What a designer needs to draw the node again; the engine ignores it.
  defp with_meta(compiled, node) do
    case Map.take(node, ~w(label position notes)) do
      meta when map_size(meta) == 0 -> compiled
      meta -> Map.put(compiled, "meta", meta)
    end
  end

  defp compile_edges(edges, nodes) when is_list(edges) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, acc} ->
      case compile_edge(edge, nodes) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_edge, edge, reason}}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp compile_edges(_edges, _nodes), do: {:error, :edges_not_a_list}

  defp compile_edge([from, to], nodes), do: compile_edge(%{"from" => from, "to" => to}, nodes)

  defp compile_edge(%{"from" => from, "to" => to} = edge, nodes) do
    cond do
      not Map.has_key?(nodes, from) ->
        {:error, {:unknown_node, from}}

      not Map.has_key?(nodes, to) ->
        {:error, {:unknown_node, to}}

      Map.get(edge, "on") not in [nil, "next", "timeout"] ->
        {:error, {:unknown_on, Map.get(edge, "on")}}

      true ->
        {:ok, Map.take(edge, ~w(from to when on branch_id))}
    end
  end

  defp compile_edge(_edge, _nodes), do: {:error, :needs_from_and_to}

  # The engine owns the rules of the graph (conditions, loop bodies, cycles
  # that never yield). Starting it on the spec runs no action and reports
  # any of them.
  defp check_with_engine(spec) do
    case Engine.init(spec, %{tenant_id: "definition-check", execution_id: "definition-check"}) do
      {:ok, _runtime} -> {:ok, spec}
      {:error, reason} -> {:error, reason}
    end
  end
end
