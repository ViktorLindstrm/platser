defmodule Platser.Map.Search.Geocoder do
  @moduledoc """
  Nominatim-compatible external geocoder for event map search.
  """

  alias Platser.Map.Search
  alias Platser.Map.Search.Geocoder.RateLimiter
  alias Platser.Map.Search.Result

  @type poi_category :: Search.poi_category()
  @type limit :: Search.limit()
  @type bounds :: Result.bounds()
  @type search_opts :: Search.search_opts()
  @type request_path :: :search | :reverse
  @type provider_kind :: :address | :place | :category

  @default_limit 5
  @request_timeout_ms 5_000
  @public_geocoder_host "nominatim.openstreetmap.org"

  @category_queries %{
    viewpoint: "viewpoint",
    camp: "camp site",
    hazard: "hazard",
    meeting_point: "meeting point",
    food: "restaurant",
    other: "place"
  }

  @doc """
  Searches the configured external provider and returns normalized results.
  """
  @spec search(String.t(), search_opts()) :: {:ok, [Result.t()]} | {:error, Result.error_reason()}
  def search(query_text, opts \\ []) do
    with {:ok, limit} <- fetch_limit(opts),
         {:ok, bounds} <- fetch_bounds(opts),
         {:ok, query} <- fetch_query(query_text, Keyword.get(opts, :category)) do
      case Search.parse_coordinates(query) do
        {:ok, point} ->
          search_coordinates(point, limit, opts)

        :error ->
          search_text(query, limit, bounds, Keyword.get(opts, :bounded?, false))
      end
    end
  end

  @spec search_coordinates(Geo.Point.t(), limit(), search_opts()) ::
          {:ok, [Result.t()]} | {:error, Result.error_reason()}
  defp search_coordinates(point, _limit, opts) do
    if Keyword.get(opts, :reverse?, true) do
      reverse_coordinate(point)
    else
      {:ok, [coordinate_result(point, nil)]}
    end
  end

  @spec reverse_coordinate(Geo.Point.t()) :: {:ok, [Result.t()]} | {:error, Result.error_reason()}
  defp reverse_coordinate(%Geo.Point{coordinates: {lng, lat}} = point) do
    params = [
      format: "jsonv2",
      addressdetails: 1,
      lat: lat,
      lon: lng
    ]

    case request(:reverse, params) do
      {:ok, %{} = body} ->
        {:ok, [coordinate_result(point, body)]}

      {:ok, _body} ->
        {:error, :malformed_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec search_text(String.t(), limit(), bounds() | nil, boolean()) ::
          {:ok, [Result.t()]} | {:error, Result.error_reason()}
  defp search_text(_query, _limit, nil, true), do: {:error, :unsupported}

  defp search_text(query, limit, bounds, bounded?) do
    params =
      [
        q: query,
        format: "jsonv2",
        addressdetails: 1,
        limit: limit
      ]
      |> maybe_put_viewbox(bounds)
      |> maybe_put_bounded(bounded?, bounds)

    case request(:search, params) do
      {:ok, body} when is_list(body) ->
        normalize_search_results(body)

      {:ok, _body} ->
        {:error, :malformed_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request(request_path(), keyword()) :: {:ok, term()} | {:error, Result.error_reason()}
  defp request(path, params) do
    maybe_wait_for_public_provider()

    request_options =
      [
        base_url: geocoder_url(),
        url: request_url(path),
        method: :get,
        params: params,
        headers: [{"user-agent", geocoder_user_agent()}],
        receive_timeout: @request_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:platser, :geocoder_req_options, []))

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :provider_rate_limited}

      {:ok, %Req.Response{status: status}} when status in 500..599 ->
        {:error, :provider_unavailable}

      {:ok, %Req.Response{status: _status}} ->
        {:error, :provider_unavailable}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, transport_error_reason(reason)}

      {:error, _error} ->
        {:error, :provider_unavailable}
    end
  end

  @spec request_url(request_path()) :: String.t()
  defp request_url(:search), do: "/search"
  defp request_url(:reverse), do: "/reverse"

  @spec normalize_search_results([term()]) :: {:ok, [Result.t()]} | {:error, :malformed_response}
  defp normalize_search_results(payloads) do
    payloads
    |> Enum.reduce_while({:ok, []}, fn payload, {:ok, results} ->
      case normalize_place(payload) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        :error -> {:halt, {:error, :malformed_response}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_place(term()) :: {:ok, Result.t()} | :error
  defp normalize_place(%{} = payload) do
    with {:ok, location} <- location_from_payload(payload),
         title when is_binary(title) <- title_from_payload(payload) do
      category = category_from_payload(payload)
      kind = kind_from_payload(payload)
      kind_label = kind_label(kind, category)
      address = address_from_payload(payload)

      {:ok,
       %Result{
         id: result_id(payload),
         source: :external,
         source_label: "OpenStreetMap",
         kind: kind,
         kind_label: kind_label,
         title: title,
         subtitle: subtitle_from_payload(payload, address),
         location: location,
         bounds: bounds_from_payload(payload),
         category: category,
         address: address,
         distance_m: nil,
         provider: :nominatim
       }}
    else
      _ -> :error
    end
  end

  defp normalize_place(_payload), do: :error

  @spec coordinate_result(Geo.Point.t(), map() | nil) :: Result.t()
  defp coordinate_result(%Geo.Point{} = point, nil) do
    %Result{
      id: coordinate_result_id(point),
      source: :external,
      source_label: "OpenStreetMap",
      kind: :coordinate,
      kind_label: "Coordinates",
      title: coordinate_title(point),
      subtitle: nil,
      location: point,
      bounds: nil,
      category: nil,
      address: nil,
      distance_m: nil,
      provider: :nominatim
    }
  end

  defp coordinate_result(%Geo.Point{} = point, %{} = payload) do
    address = address_from_payload(payload)
    display_name = string_value(payload, "display_name")

    %Result{
      id: coordinate_result_id(point),
      source: :external,
      source_label: "OpenStreetMap",
      kind: :coordinate,
      kind_label: "Coordinates",
      title: display_name || address || coordinate_title(point),
      subtitle: coordinate_title(point),
      location: point,
      bounds: bounds_from_payload(payload),
      category: category_from_payload(payload),
      address: address,
      distance_m: nil,
      provider: :nominatim
    }
  end

  @spec location_from_payload(map()) :: {:ok, Geo.Point.t()} | :error
  defp location_from_payload(payload) do
    with {:ok, lat} <- float_field(payload, "lat"),
         {:ok, lng} <- float_field(payload, "lon"),
         true <- valid_latitude?(lat),
         true <- valid_longitude?(lng) do
      {:ok, %Geo.Point{coordinates: {lng, lat}, srid: 4326}}
    else
      _ -> :error
    end
  end

  @spec bounds_from_payload(map()) :: bounds() | nil
  defp bounds_from_payload(%{"boundingbox" => [south, north, west, east]}) do
    with {:ok, south_float} <- parse_float(south),
         {:ok, north_float} <- parse_float(north),
         {:ok, west_float} <- parse_float(west),
         {:ok, east_float} <- parse_float(east),
         true <- valid_latitude?(south_float),
         true <- valid_latitude?(north_float),
         true <- valid_longitude?(west_float),
         true <- valid_longitude?(east_float) do
      %{west: west_float, south: south_float, east: east_float, north: north_float}
    else
      _ -> nil
    end
  end

  defp bounds_from_payload(_payload), do: nil

  @spec title_from_payload(map()) :: String.t() | nil
  defp title_from_payload(payload) do
    string_value(payload, "name") || first_display_name_part(payload) ||
      string_value(payload, "display_name")
  end

  @spec first_display_name_part(map()) :: String.t() | nil
  defp first_display_name_part(payload) do
    case string_value(payload, "display_name") do
      nil ->
        nil

      display_name ->
        display_name
        |> String.split(",", parts: 2)
        |> List.first()
        |> blank_to_nil()
    end
  end

  @spec subtitle_from_payload(map(), String.t() | nil) :: String.t() | nil
  defp subtitle_from_payload(payload, nil), do: string_value(payload, "display_name")

  defp subtitle_from_payload(payload, address) do
    case string_value(payload, "display_name") do
      nil -> address
      display_name -> display_name
    end
  end

  @spec address_from_payload(map()) :: String.t() | nil
  defp address_from_payload(%{"address" => address}) when is_map(address) do
    address
    |> Enum.filter(fn {_key, value} -> is_binary(value) and String.trim(value) != "" end)
    |> Enum.sort_by(fn {key, _value} -> address_sort_key(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp address_from_payload(payload), do: string_value(payload, "display_name")

  @spec address_sort_key(String.t()) :: non_neg_integer()
  defp address_sort_key("house_number"), do: 0
  defp address_sort_key("road"), do: 1
  defp address_sort_key("neighbourhood"), do: 2
  defp address_sort_key("suburb"), do: 3
  defp address_sort_key("city"), do: 4
  defp address_sort_key("town"), do: 4
  defp address_sort_key("village"), do: 4
  defp address_sort_key("municipality"), do: 5
  defp address_sort_key("county"), do: 6
  defp address_sort_key("state"), do: 7
  defp address_sort_key("country"), do: 8
  defp address_sort_key(_key), do: 9

  @spec kind_from_payload(map()) :: provider_kind()
  defp kind_from_payload(payload) do
    class = string_value(payload, "class")
    type = string_value(payload, "type")

    cond do
      class == "place" and type in ["house", "postcode"] -> :address
      class == "building" -> :address
      class == "amenity" -> :category
      class in ["shop", "tourism", "leisure", "natural"] -> :category
      true -> :place
    end
  end

  @spec kind_label(provider_kind(), String.t() | nil) :: String.t()
  defp kind_label(:address, _category), do: "Address"
  defp kind_label(:category, nil), do: "Place"
  defp kind_label(:category, category), do: humanize(category)
  defp kind_label(:place, nil), do: "Place"
  defp kind_label(:place, category), do: humanize(category)

  @spec category_from_payload(map()) :: String.t() | nil
  defp category_from_payload(payload) do
    string_value(payload, "type") || string_value(payload, "class")
  end

  @spec result_id(map()) :: String.t()
  defp result_id(payload) do
    id_part =
      string_value(payload, "place_id") ||
        osm_identifier(payload) ||
        Base.url_encode64(:erlang.term_to_binary(payload), padding: false)

    "external:nominatim:#{id_part}"
  end

  @spec osm_identifier(map()) :: String.t() | nil
  defp osm_identifier(payload) do
    with osm_type when is_binary(osm_type) <- string_value(payload, "osm_type"),
         osm_id when is_binary(osm_id) <- string_value(payload, "osm_id") do
      "#{osm_type}:#{osm_id}"
    else
      _ -> nil
    end
  end

  @spec coordinate_result_id(Geo.Point.t()) :: String.t()
  defp coordinate_result_id(%Geo.Point{coordinates: {lng, lat}}) do
    "external:nominatim:coordinate:#{Float.round(lat, 6)},#{Float.round(lng, 6)}"
  end

  @spec coordinate_title(Geo.Point.t()) :: String.t()
  defp coordinate_title(%Geo.Point{coordinates: {lng, lat}}) do
    "#{Float.round(lat, 6)}, #{Float.round(lng, 6)}"
  end

  @spec maybe_put_viewbox(keyword(), bounds() | nil) :: keyword()
  defp maybe_put_viewbox(params, nil), do: params

  defp maybe_put_viewbox(params, bounds) do
    Keyword.put(params, :viewbox, "#{bounds.west},#{bounds.north},#{bounds.east},#{bounds.south}")
  end

  @spec maybe_put_bounded(keyword(), boolean(), bounds() | nil) :: keyword()
  defp maybe_put_bounded(params, true, %{}), do: Keyword.put(params, :bounded, 1)
  defp maybe_put_bounded(params, _bounded?, _bounds), do: params

  @spec fetch_query(String.t(), poi_category() | nil) ::
          {:ok, String.t()} | {:error, Result.error_reason()}
  defp fetch_query(query_text, category) do
    query =
      query_text
      |> String.trim()
      |> blank_to_nil()

    category_query = category_query(category)

    case {query, category_query} do
      {nil, nil} -> {:error, :invalid_query}
      {nil, provider_query} -> {:ok, provider_query}
      {text, nil} -> {:ok, text}
      {text, provider_query} -> {:ok, "#{text} #{provider_query}"}
    end
  end

  @spec category_query(poi_category() | nil | term()) :: String.t() | nil
  defp category_query(nil), do: nil

  defp category_query(category) when is_atom(category) do
    Map.get(@category_queries, category)
  end

  defp category_query(_category), do: nil

  @spec fetch_limit(search_opts()) :: {:ok, limit()} | {:error, :invalid_limit}
  defp fetch_limit(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if is_integer(limit) and limit in 1..50 do
      {:ok, limit}
    else
      {:error, :invalid_limit}
    end
  end

  @spec fetch_bounds(search_opts()) :: {:ok, bounds() | nil} | {:error, :invalid_bounds}
  defp fetch_bounds(opts) do
    case Keyword.get(opts, :bounds) do
      nil ->
        {:ok, nil}

      %{west: west, south: south, east: east, north: north} ->
        validate_bounds(west, south, east, north)

      _bounds ->
        {:error, :invalid_bounds}
    end
  end

  @spec validate_bounds(term(), term(), term(), term()) ::
          {:ok, bounds()} | {:error, :invalid_bounds}
  defp validate_bounds(west, south, east, north)
       when is_number(west) and is_number(south) and is_number(east) and is_number(north) do
    west_float = west / 1
    south_float = south / 1
    east_float = east / 1
    north_float = north / 1

    if valid_longitude?(west_float) and valid_longitude?(east_float) and
         valid_latitude?(south_float) and valid_latitude?(north_float) and
         west_float <= east_float and
         south_float <= north_float do
      {:ok, %{west: west_float, south: south_float, east: east_float, north: north_float}}
    else
      {:error, :invalid_bounds}
    end
  end

  defp validate_bounds(_west, _south, _east, _north), do: {:error, :invalid_bounds}

  @spec float_field(map(), String.t()) :: {:ok, float()} | :error
  defp float_field(payload, key) do
    payload
    |> Map.get(key)
    |> parse_float()
  end

  @spec parse_float(term()) :: {:ok, float()} | :error
  defp parse_float(value) when is_float(value), do: {:ok, value}
  defp parse_float(value) when is_integer(value), do: {:ok, value / 1}

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp parse_float(_value), do: :error

  @spec valid_latitude?(float()) :: boolean()
  defp valid_latitude?(value), do: finite?(value) and value >= -90.0 and value <= 90.0

  @spec valid_longitude?(float()) :: boolean()
  defp valid_longitude?(value), do: finite?(value) and value >= -180.0 and value <= 180.0

  @spec finite?(float()) :: boolean()
  defp finite?(value), do: value == value and value - value == 0.0

  @spec string_value(map(), String.t()) :: String.t() | nil
  defp string_value(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> blank_to_nil(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _value -> nil
    end
  end

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec humanize(String.t()) :: String.t()
  defp humanize(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @spec transport_error_reason(term()) :: Result.error_reason()
  defp transport_error_reason(reason) when reason in [:timeout, :closed], do: :provider_timeout
  defp transport_error_reason(_reason), do: :provider_unavailable

  @spec maybe_wait_for_public_provider() :: :ok
  defp maybe_wait_for_public_provider do
    if public_provider?() and Application.get_env(:platser, :geocoder_rate_limit_public?, true) do
      RateLimiter.wait()
    else
      :ok
    end
  end

  @spec public_provider?() :: boolean()
  defp public_provider? do
    case URI.parse(geocoder_url()) do
      %URI{host: @public_geocoder_host} -> true
      _uri -> false
    end
  end

  @spec geocoder_url() :: String.t()
  defp geocoder_url do
    Application.get_env(:platser, :geocoder_url, "https://nominatim.openstreetmap.org")
  end

  @spec geocoder_user_agent() :: String.t()
  defp geocoder_user_agent do
    Application.get_env(:platser, :geocoder_user_agent, "Platser/0.1")
  end
end
