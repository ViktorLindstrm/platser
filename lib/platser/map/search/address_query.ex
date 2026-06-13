defmodule Platser.Map.Search.AddressQuery do
  @moduledoc """
  Conservative parser for Nominatim structured address retries.
  """

  @type component_key :: :street | :city | :country | :postalcode
  @type components :: %{optional(component_key()) => String.t()}
  @type parse_result :: {:ok, components()} | :error

  @max_component_length 120
  @house_number_pattern ~r/(?:^|\s)\d+[[:alnum:]\-\/]*$/u
  @leading_house_number_pattern ~r/^\d+[[:alnum:]\-\/]*\s+\S+/u
  @postalcode_pattern ~r/^\d{3}\s?\d{2}$|^[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}$/iu

  @doc """
  Parses obvious address-looking text into Nominatim structured search fields.

  The parser intentionally supports only small, low-surprise shapes. Ambiguous
  place or POI queries return `:error` and stay on free-form search only.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(query_text) do
    query_text
    |> normalize_query()
    |> do_parse()
  end

  @spec normalize_query(String.t()) :: String.t()
  defp normalize_query(query_text) do
    query_text
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  @spec do_parse(String.t()) :: parse_result()
  defp do_parse(""), do: :error

  defp do_parse(query) do
    parts =
      query
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parse_parts(parts)
  end

  @spec parse_parts([String.t()]) :: parse_result()
  defp parse_parts([street]) do
    if street_address?(street) do
      {:ok, %{street: clamp_component(street)}}
    else
      :error
    end
  end

  defp parse_parts([first, second]) do
    cond do
      street_address?(first) ->
        {:ok, second_component(%{street: clamp_component(first)}, second)}

      postalcode?(first) and street_address?(second) ->
        {:ok, %{postalcode: clamp_component(first), street: clamp_component(second)}}

      true ->
        :error
    end
  end

  defp parse_parts([street, city, third | _rest]) do
    if street_address?(street) do
      components =
        %{street: clamp_component(street), city: clamp_component(city)}
        |> third_component(third)

      {:ok, components}
    else
      :error
    end
  end

  defp parse_parts(_parts), do: :error

  @spec second_component(components(), String.t()) :: components()
  defp second_component(components, value) do
    key = if postalcode?(value), do: :postalcode, else: :city
    Map.put(components, key, clamp_component(value))
  end

  @spec third_component(components(), String.t()) :: components()
  defp third_component(components, value) do
    key = if postalcode?(value), do: :postalcode, else: :country
    Map.put(components, key, clamp_component(value))
  end

  @spec street_address?(String.t()) :: boolean()
  defp street_address?(value) do
    String.match?(value, @house_number_pattern) or
      String.match?(value, @leading_house_number_pattern)
  end

  @spec postalcode?(String.t()) :: boolean()
  defp postalcode?(value), do: String.match?(value, @postalcode_pattern)

  @spec clamp_component(String.t()) :: String.t()
  defp clamp_component(value) do
    value
    |> String.slice(0, @max_component_length)
    |> String.trim()
  end
end
