defmodule Platser.Map.Search do
  @moduledoc """
  Event map search boundary.

  This module owns normalized search behavior outside Ash persistence. The
  internal search path reads POIs through Ash actions so event membership,
  draft visibility, and admin visibility remain policy-controlled.
  """

  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Poi
  alias Platser.Map.Search.Result

  @type poi_category :: :viewpoint | :camp | :hazard | :meeting_point | :food | :other
  @type search_error :: :invalid_limit
  @type limit :: 1..50
  @type search_opts :: [
          origin: Geo.Point.t() | nil,
          nearby_radius_m: non_neg_integer(),
          limit: limit()
        ]

  @poi_categories [:viewpoint, :camp, :hazard, :meeting_point, :food, :other]
  @default_limit 10
  @default_nearby_radius_m 1_000
  @earth_radius_m 6_371_000.0

  @doc """
  Searches POIs visible to `actor` inside `event_id`.

  Text queries match POI name, description, and category labels. Coordinate
  queries match nearby POIs within `:nearby_radius_m`. When `:origin` is passed,
  returned text matches include distance metadata and are distance-sorted.
  """
  @spec search_internal(Ecto.UUID.t(), String.t(), Platser.Accounts.User.t(), search_opts()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def search_internal(event_id, query_text, actor, opts \\ []) do
    with {:ok, limit} <- fetch_limit(opts),
         {:ok, pois} <- PlatserMap.list_pois_for_event(event_id, actor: actor) do
      query = normalize_query(query_text)
      origin = search_origin(query, Keyword.get(opts, :origin))
      radius_m = Keyword.get(opts, :nearby_radius_m, @default_nearby_radius_m)

      results =
        pois
        |> filter_pois(query, origin, radius_m)
        |> sort_pois(query, origin)
        |> Enum.take(limit)
        |> Enum.map(&to_internal_result(&1, origin))

      {:ok, results}
    end
  end

  @doc """
  Parses strict latitude/longitude text into a WGS84 point stored as `{lng, lat}`.
  """
  @spec parse_coordinates(String.t()) :: {:ok, Geo.Point.t()} | :error
  def parse_coordinates(query_text) do
    parts =
      query_text
      |> String.trim()
      |> String.split([",", " "], trim: true)

    case parts do
      [lat_text, lng_text] ->
        with {:ok, lat} <- parse_float(lat_text),
             {:ok, lng} <- parse_float(lng_text),
             true <- finite_latitude?(lat),
             true <- finite_longitude?(lng) do
          {:ok, %Geo.Point{coordinates: {lng, lat}, srid: 4326}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Returns the display label for an app POI category.
  """
  @spec category_label(poi_category()) :: String.t()
  def category_label(:viewpoint), do: "Viewpoint"
  def category_label(:camp), do: "Camp"
  def category_label(:hazard), do: "Hazard"
  def category_label(:meeting_point), do: "Meeting point"
  def category_label(:food), do: "Food"
  def category_label(:other), do: "Other"

  @spec fetch_limit(search_opts()) :: {:ok, limit()} | {:error, search_error()}
  defp fetch_limit(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if is_integer(limit) and limit in 1..50 do
      {:ok, limit}
    else
      {:error, :invalid_limit}
    end
  end

  @spec normalize_query(String.t()) :: String.t()
  defp normalize_query(query_text) do
    query_text
    |> String.trim()
    |> String.downcase()
  end

  @spec search_origin(String.t(), Geo.Point.t() | nil) :: Geo.Point.t() | nil
  defp search_origin("", origin), do: origin

  defp search_origin(query, origin) do
    case parse_coordinates(query) do
      {:ok, point} -> point
      :error -> origin
    end
  end

  @spec filter_pois([Poi.t()], String.t(), Geo.Point.t() | nil, non_neg_integer()) :: [Poi.t()]
  defp filter_pois(pois, "", nil, _radius_m), do: pois

  defp filter_pois(pois, "", origin, radius_m) do
    Enum.filter(pois, &within_radius?(&1.location, origin, radius_m))
  end

  defp filter_pois(pois, query, origin, radius_m) do
    coordinate_query? = match?({:ok, _point}, parse_coordinates(query))

    Enum.filter(pois, fn poi ->
      cond do
        coordinate_query? and not is_nil(origin) ->
          within_radius?(poi.location, origin, radius_m)

        true ->
          text_match?(poi, query)
      end
    end)
  end

  @spec sort_pois([Poi.t()], String.t(), Geo.Point.t() | nil) :: [Poi.t()]
  defp sort_pois(pois, query, origin) do
    Enum.sort_by(pois, fn poi ->
      {distance_sort(poi.location, origin), relevance_sort(poi, query), String.downcase(poi.name)}
    end)
  end

  @spec distance_sort(Geo.Point.t(), Geo.Point.t() | nil) :: non_neg_integer()
  defp distance_sort(_location, nil), do: 0
  defp distance_sort(location, origin), do: distance_m(location, origin)

  @spec relevance_sort(Poi.t(), String.t()) :: 0..3
  defp relevance_sort(_poi, ""), do: 3

  defp relevance_sort(poi, query) do
    cond do
      String.downcase(poi.name) == query -> 0
      String.starts_with?(String.downcase(poi.name), query) -> 1
      category_matches?(poi.category, query) -> 2
      true -> 3
    end
  end

  @spec text_match?(Poi.t(), String.t()) :: boolean()
  defp text_match?(poi, query) do
    String.contains?(String.downcase(poi.name), query) or
      String.contains?(String.downcase(poi.description || ""), query) or
      category_matches?(poi.category, query)
  end

  @spec category_matches?(poi_category(), String.t()) :: boolean()
  defp category_matches?(category, query) when category in @poi_categories do
    category
    |> category_search_terms()
    |> Enum.any?(&String.contains?(&1, query))
  end

  @spec category_search_terms(poi_category()) :: [String.t()]
  defp category_search_terms(category) do
    atom_text = category |> Atom.to_string() |> String.replace("_", " ")
    [atom_text, String.downcase(category_label(category))]
  end

  @spec to_internal_result(Poi.t(), Geo.Point.t() | nil) :: Result.t()
  defp to_internal_result(%Poi{} = poi, origin) do
    %Result{
      id: "internal:poi:#{poi.id}",
      source: :internal,
      source_label: "Event POI",
      kind: :poi,
      kind_label: category_label(poi.category),
      title: poi.name,
      subtitle: result_subtitle(poi, origin),
      location: poi.location,
      bounds: nil,
      category: poi.category,
      address: nil,
      distance_m: distance_or_nil(poi.location, origin),
      provider: nil
    }
  end

  @spec result_subtitle(Poi.t(), Geo.Point.t() | nil) :: String.t() | nil
  defp result_subtitle(poi, nil), do: poi.description || category_label(poi.category)

  defp result_subtitle(poi, origin) do
    "#{category_label(poi.category)} · #{distance_m(poi.location, origin)} m away"
  end

  @spec distance_or_nil(Geo.Point.t(), Geo.Point.t() | nil) :: non_neg_integer() | nil
  defp distance_or_nil(_location, nil), do: nil
  defp distance_or_nil(location, origin), do: distance_m(location, origin)

  @spec within_radius?(Geo.Point.t(), Geo.Point.t(), non_neg_integer()) :: boolean()
  defp within_radius?(location, origin, radius_m) do
    distance_m(location, origin) <= radius_m
  end

  @spec distance_m(Geo.Point.t(), Geo.Point.t()) :: non_neg_integer()
  defp distance_m(
         %Geo.Point{coordinates: {lng_a, lat_a}},
         %Geo.Point{coordinates: {lng_b, lat_b}}
       ) do
    lat_a_rad = radians(lat_a)
    lat_b_rad = radians(lat_b)
    delta_lat = radians(lat_b - lat_a)
    delta_lng = radians(lng_b - lng_a)

    a =
      :math.sin(delta_lat / 2) * :math.sin(delta_lat / 2) +
        :math.cos(lat_a_rad) *
          :math.cos(lat_b_rad) *
          :math.sin(delta_lng / 2) *
          :math.sin(delta_lng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    round(@earth_radius_m * c)
  end

  @spec radians(float()) :: float()
  defp radians(degrees), do: degrees * :math.pi() / 180.0

  @spec parse_float(String.t()) :: {:ok, float()} | :error
  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  @spec finite_latitude?(float()) :: boolean()
  defp finite_latitude?(value), do: finite?(value) and value >= -90.0 and value <= 90.0

  @spec finite_longitude?(float()) :: boolean()
  defp finite_longitude?(value), do: finite?(value) and value >= -180.0 and value <= 180.0

  @spec finite?(float()) :: boolean()
  defp finite?(value), do: value == value and value - value == 0.0
end
