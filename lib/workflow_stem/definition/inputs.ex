defmodule WorkflowStem.Definition.Inputs do
  @moduledoc """
  The settings a workflow declares — its dials.

      "inputs" => %{
        "interval_minutes" => %{"type" => "integer", "default" => 15, "min" => 5,
                                "label" => "Check every (minutes)"},
        "statuses" => %{"type" => "list", "default" => ["confirmed"]}
      }

  `resolve/2` turns what a client chose (or what a form posted, as text) into
  the values a run reads as `{{params.…}}`, or says exactly which setting is
  wrong. `describe/1` is the declaration in the shape a settings form renders
  from, so no form is written per workflow.

  Types: `string`, `integer`, `number`, `boolean`, `date`, `list`, `map`.
  A declaration may also carry `required`, `default`, `min`, `max`, `enum`,
  `label`, `help` and `order`.
  """

  @types ~w(string integer number boolean date list map)

  @type declared :: %{optional(String.t()) => map()}

  @doc "Checks a declaration itself: known types, defaults that satisfy their own rules."
  @spec validate(term()) :: :ok | {:error, %{String.t() => term()}}
  def validate(nil), do: :ok

  def validate(%{} = declared) do
    errors =
      for {name, spec} <- declared, reduce: %{} do
        acc ->
          case validate_declaration(spec) do
            :ok -> acc
            {:error, reason} -> Map.put(acc, to_string(name), reason)
          end
      end

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  def validate(_declared), do: {:error, %{"inputs" => :not_a_map}}

  @doc "Resolves given values against the declaration: defaults, coercion, limits."
  @spec resolve(declared() | nil, map() | nil) :: {:ok, map()} | {:error, %{String.t() => term()}}
  def resolve(declared, given) do
    declared = declared || %{}
    given = stringify(given || %{})

    {params, errors} =
      Enum.reduce(declared, {%{}, %{}}, fn {name, spec}, {params, errors} ->
        name = to_string(name)

        case resolve_one(spec, Map.fetch(given, name)) do
          {:ok, :absent} -> {params, errors}
          {:ok, value} -> {Map.put(params, name, value), errors}
          {:error, reason} -> {params, Map.put(errors, name, reason)}
        end
      end)

    if errors == %{}, do: {:ok, params}, else: {:error, errors}
  end

  @doc "The declaration as an ordered list of fields for a settings form."
  @spec describe(declared() | nil) :: [map()]
  def describe(declared) do
    (declared || %{})
    |> Enum.map(fn {name, spec} ->
      %{
        name: to_string(name),
        type: get(spec, "type") || "string",
        label: get(spec, "label") || to_string(name),
        help: get(spec, "help"),
        default: get(spec, "default"),
        required: get(spec, "required") == true,
        min: get(spec, "min"),
        max: get(spec, "max"),
        enum: get(spec, "enum"),
        order: get(spec, "order")
      }
    end)
    |> Enum.sort_by(&{&1.order || 1_000_000, &1.name})
  end

  defp validate_declaration(%{} = spec) do
    type = get(spec, "type") || "string"

    cond do
      type not in @types ->
        {:error, {:unknown_type, type}}

      not is_nil(get(spec, "enum")) and not is_list(get(spec, "enum")) ->
        {:error, :enum_not_a_list}

      is_nil(get(spec, "default")) ->
        :ok

      true ->
        case check(spec, get(spec, "default")) do
          {:ok, _value} -> :ok
          {:error, reason} -> {:error, {:invalid_default, reason}}
        end
    end
  end

  defp validate_declaration(_spec), do: {:error, :not_a_map}

  defp resolve_one(spec, :error), do: default(spec)
  defp resolve_one(spec, {:ok, value}) when value in [nil, ""], do: default(spec)
  defp resolve_one(spec, {:ok, value}), do: check(spec, value)

  defp default(spec) do
    cond do
      not is_nil(get(spec, "default")) -> check(spec, get(spec, "default"))
      get(spec, "required") == true -> {:error, :required}
      true -> {:ok, :absent}
    end
  end

  defp check(spec, value) do
    with {:ok, value} <- coerce(get(spec, "type") || "string", value),
         :ok <- within(value, get(spec, "min"), get(spec, "max")),
         :ok <- one_of(value, get(spec, "enum")) do
      {:ok, value}
    end
  end

  defp coerce("string", value) when is_binary(value), do: {:ok, value}
  defp coerce("string", value) when is_number(value), do: {:ok, to_string(value)}

  defp coerce("integer", value) when is_integer(value), do: {:ok, value}

  defp coerce("integer", value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :not_an_integer}
    end
  end

  defp coerce("number", value) when is_number(value), do: {:ok, value}

  defp coerce("number", value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :not_a_number}
    end
  end

  defp coerce("boolean", value) when is_boolean(value), do: {:ok, value}
  defp coerce("boolean", value) when value in ["true", "on", "1"], do: {:ok, true}
  defp coerce("boolean", value) when value in ["false", "off", "0"], do: {:ok, false}

  defp coerce("date", %Date{} = value), do: {:ok, Date.to_iso8601(value)}

  defp coerce("date", value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, :not_a_date}
    end
  end

  defp coerce("list", value) when is_list(value), do: {:ok, value}

  defp coerce("list", value) when is_binary(value),
    do: {:ok, value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}

  defp coerce("map", %{} = value), do: {:ok, value}
  defp coerce(type, _value), do: {:error, {:not_a, type}}

  defp within(value, min, max) when is_number(value) do
    cond do
      is_number(min) and value < min -> {:error, {:below_min, min}}
      is_number(max) and value > max -> {:error, {:above_max, max}}
      true -> :ok
    end
  end

  defp within(_value, _min, _max), do: :ok

  defp one_of(_value, nil), do: :ok

  defp one_of(value, options) when is_list(value) do
    case value -- options do
      [] -> :ok
      unknown -> {:error, {:not_in_enum, unknown}}
    end
  end

  defp one_of(value, options),
    do: if(value in options, do: :ok, else: {:error, {:not_in_enum, value}})

  defp get(%{} = spec, key) do
    case Map.fetch(spec, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(spec, fn
          {atom, value} when is_atom(atom) -> if Atom.to_string(atom) == key, do: value
          _ -> nil
        end)
    end
  end

  defp stringify(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
