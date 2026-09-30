defmodule WorkflowStem.Definition.Template do
  @moduledoc """
  References from one part of a workflow definition to the run's data.

      "{{params.lookback_days}}"      a dial
      "{{search.body.reservations}}"  what the node `search` produced
      "{{item.id}}"                   the current item inside a for_each

  A value that is exactly one reference keeps the type of what it points at
  (a list stays a list). References inside longer text are written into the
  text.

  A reference that resolves to nothing is an error: a provider call whose
  date filter quietly became an empty string asks for everything. Mark a
  reference optional with `?` — `{{?guest.phone}}` — to allow it to be absent.
  """

  alias Mobus.Stepwise.Condition

  @reference ~r/\{\{\s*(\??)\s*([A-Za-z0-9_][A-Za-z0-9_.\-]*)\s*\}\}/
  @whole ~r/\A\s*\{\{\s*(\??)\s*([A-Za-z0-9_][A-Za-z0-9_.\-]*)\s*\}\}\s*\z/

  @type error :: {:unresolved_reference, String.t()}

  @doc "Renders every reference in a term: strings, and maps and lists of them."
  @spec render(term(), map()) :: {:ok, term()} | {:error, error()}
  def render(value, context) when is_map(context) do
    {:ok, do_render(value, context)}
  catch
    {:unresolved_reference, _path} = error -> {:error, error}
  end

  @doc "The dotted path a whole-value reference points at, or `nil`."
  @spec reference_path(term()) :: String.t() | nil
  def reference_path(value) when is_binary(value) do
    case Regex.run(@whole, value) do
      [_, _optional, path] -> path
      nil -> nil
    end
  end

  def reference_path(_value), do: nil

  defp do_render(value, context) when is_binary(value) do
    case Regex.run(@whole, value) do
      [_, optional, path] -> resolve(path, optional, context)
      nil -> interpolate(value, context)
    end
  end

  defp do_render(%{} = map, context) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, do_render(value, context)} end)

  defp do_render(list, context) when is_list(list), do: Enum.map(list, &do_render(&1, context))
  defp do_render(value, _context), do: value

  defp interpolate(text, context) do
    Regex.replace(@reference, text, fn _match, optional, path ->
      path |> resolve(optional, context) |> to_text()
    end)
  end

  defp resolve(path, optional, context) do
    case Condition.resolve_path(path, context) do
      nil when optional == "?" -> nil
      nil -> throw({:unresolved_reference, path})
      value -> value
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value) when is_float(value), do: Float.to_string(value)
  defp to_text(value) when is_boolean(value), do: to_string(value)
  defp to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp to_text(%Date{} = value), do: Date.to_iso8601(value)
  defp to_text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp to_text(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
