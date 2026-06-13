defmodule Platser.Map.Search.Geocoder do
  @moduledoc """
  Nominatim-compatible external geocoder for event map search.
  """

  alias Platser.Map.Search
  alias Platser.Map.Search.AddressQuery
  alias Platser.Map.Search.Geocoder.Cache
  alias Platser.Map.Search.Geocoder.RateLimiter
  alias Platser.Map.Search.Result

  @type poi_category :: Search.poi_category()
  @type limit :: Search.limit()
  @type bounds :: Result.bounds()
  @type search_opts :: Search.search_opts()
  @type provider_context :: %{
          bounds: bounds() | nil,
          bounded?: boolean(),
          accept_language: String.t() | nil,
          countrycodes: [String.t()] | nil
        }
  @type request_path :: :search | :reverse
  @type provider_kind :: :address | :place | :category
  @type search_form :: :free_form | :structured
  @type cache_key :: Cache.key()

  @default_limit 5
  @request_timeout_ms 5_000
  @public_geocoder_host "nominatim.openstreetmap.org"
  @address_types ["address", "building", "house", "postcode", "residential"]
  @address_addresstypes ["address", "building", "house", "postcode", "residential", "road"]
  @category_categories ["amenity", "shop", "tourism", "leisure", "natural"]

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
         {:ok, context} <- fetch_provider_context(opts),
         {:ok, query} <- fetch_query(query_text, Keyword.get(opts, :category)) do
      Cache.fetch(cache_key(query, limit, context, opts), fn ->
        case Search.parse_coordinates(query) do
          {:ok, point} ->
            search_coordinates(point, limit, opts)

          :error ->
            search_text(query, limit, context)
        end
      end)
    end
  end

  @doc """
  Returns the normalized cache key used for an external search request.
  """
  @spec cache_key(String.t(), search_opts()) ::
          {:ok, cache_key()} | {:error, Result.error_reason()}
  def cache_key(query_text, opts \\ []) do
    with {:ok, limit} <- fetch_limit(opts),
         {:ok, context} <- fetch_provider_context(opts),
         {:ok, query} <- fetch_query(query_text, Keyword.get(opts, :category)) do
      {:ok, cache_key(query, limit, context, opts)}
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

  @spec search_text(String.t(), limit(), provider_context()) ::
          {:ok, [Result.t()]} | {:error, Result.error_reason()}
  defp search_text(_query, _limit, %{bounds: nil, bounded?: true}), do: {:error, :unsupported}

  defp search_text(query, limit, context) do
    params = search_params(query, limit, context)

    case search_provider(params) do
      {:ok, body} when is_list(body) ->
        with {:ok, results} <- normalize_search_results(body) do
          maybe_retry_structured_search(query, results, limit, context)
        end

      {:ok, _body} ->
        {:error, :malformed_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec search_provider(keyword()) :: {:ok, term()} | {:error, Result.error_reason()}
  defp search_provider(params), do: request(:search, params)

  @spec cache_key(String.t(), limit(), provider_context(), search_opts()) :: cache_key()
  defp cache_key(query, limit, context, opts) do
    mode =
      case Search.parse_coordinates(query) do
        {:ok, %Geo.Point{coordinates: {lng, lat}}} ->
          %{type: :coordinate, lat: lat, lng: lng, reverse?: Keyword.get(opts, :reverse?, true)}

        :error ->
          %{type: :text, query: query, category: Keyword.get(opts, :category)}
      end

    Cache.key(%{
      version: 1,
      provider: :nominatim,
      provider_url: geocoder_url(),
      response_format: "jsonv2",
      limit: limit,
      mode: mode,
      bounds: context.bounds,
      bounded?: context.bounded?,
      accept_language: context.accept_language,
      countrycodes: context.countrycodes
    })
  end

  @spec search_params(String.t(), limit(), provider_context()) :: keyword()
  defp search_params(query, limit, context) do
    [
      q: query,
      format: "jsonv2",
      addressdetails: 1,
      limit: limit
    ]
    |> maybe_put_context(context)
  end

  @spec structured_search_params(AddressQuery.components(), limit(), provider_context()) ::
          keyword()
  defp structured_search_params(components, limit, context) do
    components
    |> Map.to_list()
    |> Keyword.merge(format: "jsonv2", addressdetails: 1, limit: limit)
    |> maybe_put_context(context)
  end

  @spec maybe_retry_structured_search(
          String.t(),
          [Result.t()],
          limit(),
          provider_context()
        ) ::
          {:ok, [Result.t()]} | {:error, Result.error_reason()}
  defp maybe_retry_structured_search(query, results, limit, context) do
    with true <- structured_retry_needed?(query, results),
         {:ok, components} <- AddressQuery.parse(query) do
      params =
        structured_search_params(components, limit, structured_retry_context(context))

      case search_provider(params) do
        {:ok, body} when is_list(body) ->
          with {:ok, structured_results} <- normalize_search_results(body) do
            {:ok, structured_retry_results(results, structured_results)}
          end

        {:ok, _body} ->
          {:error, :malformed_response}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _fallback_not_needed_or_unsupported -> {:ok, results}
    end
  end

  @spec structured_retry_needed?(String.t(), [Result.t()]) :: boolean()
  defp structured_retry_needed?(query, results) do
    match?({:ok, _components}, AddressQuery.parse(query)) and
      (results == [] or not Enum.any?(results, &useful_address_result?(query, &1)))
  end

  @spec structured_bounded?(boolean(), bounds() | nil) :: boolean()
  defp structured_bounded?(true, _bounds), do: true
  defp structured_bounded?(false, nil), do: false
  defp structured_bounded?(false, %{}), do: true

  @spec structured_retry_context(provider_context()) :: provider_context()
  defp structured_retry_context(%{bounds: bounds, bounded?: bounded?} = context) do
    %{context | bounded?: structured_bounded?(bounded?, bounds)}
  end

  @spec useful_address_result?(String.t(), Result.t()) :: boolean()
  defp useful_address_result?(query, %Result{} = result) do
    query_terms = query_terms(query)
    haystack = String.downcase(Enum.join([result.title, result.subtitle, result.address], " "))

    result.kind == :address and Enum.all?(query_terms, &String.contains?(haystack, &1))
  end

  @spec query_terms(String.t()) :: [String.t()]
  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split([",", " "], trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end

  @spec structured_retry_results([Result.t()], [Result.t()]) :: [Result.t()]
  defp structured_retry_results(_weak_results, []), do: []

  defp structured_retry_results(results, structured_results),
    do: merge_results(results, structured_results)

  @spec merge_results([Result.t()], [Result.t()]) :: [Result.t()]
  defp merge_results(results, structured_results) do
    structured_results
    |> Kernel.++(results)
    |> Enum.uniq_by(& &1.id)
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
         source_label: "Map",
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
      source_label: "Map",
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
      source_label: "Map",
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
    if address_like_payload?(payload) do
      address_title_from_payload(payload) || first_display_name_part(payload) ||
        string_value(payload, "name") || string_value(payload, "display_name")
    else
      string_value(payload, "name") || first_display_name_part(payload) ||
        string_value(payload, "display_name")
    end
  end

  @spec address_title_from_payload(map()) :: String.t() | nil
  defp address_title_from_payload(%{"address" => address}) when is_map(address) do
    street_line =
      [
        string_value(address, "road") || string_value(address, "pedestrian") ||
          string_value(address, "footway") || string_value(address, "cycleway") ||
          string_value(address, "path"),
        string_value(address, "house_number") || string_value(address, "house_name")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> blank_to_nil()

    street_line || address_area_title(address)
  end

  defp address_title_from_payload(payload) do
    payload
    |> string_value("display_name")
    |> address_title_from_display_name()
  end

  @spec address_area_title(map()) :: String.t() | nil
  defp address_area_title(address) do
    address
    |> ordered_address_parts()
    |> Enum.take(2)
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  @spec address_title_from_display_name(String.t() | nil) :: String.t() | nil
  defp address_title_from_display_name(nil), do: nil

  defp address_title_from_display_name(display_name) do
    parts =
      display_name
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parts do
      [number, street | _rest] ->
        if numeric_label?(number), do: "#{street} #{number}", else: number

      [first | _rest] ->
        first

      [] ->
        nil
    end
  end

  @spec numeric_label?(String.t()) :: boolean()
  defp numeric_label?(value) do
    Regex.match?(~r/\A\d+[[:alnum:]\/-]*\z/u, value)
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
    |> Enum.reduce(%{}, fn {key, value}, parts ->
      if useful_address_key?(key) and is_binary(value) and String.trim(value) != "" do
        Map.put(parts, key, String.trim(value))
      else
        parts
      end
    end)
    |> ordered_address_parts()
    |> Enum.uniq()
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp address_from_payload(payload), do: string_value(payload, "display_name")

  @spec useful_address_key?(term()) :: boolean()
  defp useful_address_key?(key) when is_binary(key) do
    not (key == "country_code" or String.starts_with?(key, "ISO3166-"))
  end

  defp useful_address_key?(_key), do: false

  @spec ordered_address_parts(%{optional(String.t()) => String.t()}) :: [String.t()]
  defp ordered_address_parts(address) do
    street_line =
      [
        Map.get(address, "road"),
        Map.get(address, "house_number") || Map.get(address, "house_name")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> blank_to_nil()

    address
    |> Enum.reject(fn {key, _value} -> key in ["road", "house_number", "house_name"] end)
    |> Enum.sort_by(fn {key, _value} -> address_sort_key(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> prepend_if_present(street_line)
  end

  @spec prepend_if_present([String.t()], String.t() | nil) :: [String.t()]
  defp prepend_if_present(values, nil), do: values
  defp prepend_if_present(values, value), do: [value | values]

  @spec address_sort_key(String.t()) :: non_neg_integer()
  defp address_sort_key("house_number"), do: 0
  defp address_sort_key("house_name"), do: 0
  defp address_sort_key("road"), do: 1
  defp address_sort_key("square"), do: 1
  defp address_sort_key("place"), do: 1
  defp address_sort_key("amenity"), do: 1
  defp address_sort_key("neighbourhood"), do: 2
  defp address_sort_key("suburb"), do: 3
  defp address_sort_key("city"), do: 4
  defp address_sort_key("town"), do: 4
  defp address_sort_key("village"), do: 4
  defp address_sort_key("municipality"), do: 5
  defp address_sort_key("county"), do: 6
  defp address_sort_key("state"), do: 7
  defp address_sort_key("postcode"), do: 8
  defp address_sort_key("country"), do: 9
  defp address_sort_key(_key), do: 9

  @spec kind_from_payload(map()) :: provider_kind()
  defp kind_from_payload(payload) do
    category = provider_category(payload)
    type = provider_type(payload)

    cond do
      address_like_payload?(payload) -> :address
      category in @category_categories -> :category
      category == nil and type not in [nil | @address_types] -> :category
      true -> :place
    end
  end

  @spec address_like_payload?(map()) :: boolean()
  defp address_like_payload?(payload) do
    category = provider_category(payload)
    type = provider_type(payload)
    addresstype = provider_addresstype(payload)

    type in @address_types or addresstype in @address_addresstypes or category == "building" or
      (category == "place" and type in ["house", "postcode"])
  end

  @spec kind_label(provider_kind(), String.t() | nil) :: String.t()
  defp kind_label(:address, _category), do: "Address"
  defp kind_label(:category, nil), do: "Place"
  defp kind_label(:category, category), do: humanize(category)
  defp kind_label(:place, nil), do: "Place"
  defp kind_label(:place, category), do: humanize(category)

  @spec category_from_payload(map()) :: String.t() | nil
  defp category_from_payload(payload) do
    provider_type(payload) || provider_category(payload) || provider_addresstype(payload)
  end

  @spec provider_category(map()) :: String.t() | nil
  defp provider_category(payload) do
    string_value(payload, "category") || string_value(payload, "class")
  end

  @spec provider_type(map()) :: String.t() | nil
  defp provider_type(payload), do: string_value(payload, "type")

  @spec provider_addresstype(map()) :: String.t() | nil
  defp provider_addresstype(payload), do: string_value(payload, "addresstype")

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

  @spec maybe_put_context(keyword(), provider_context()) :: keyword()
  defp maybe_put_context(params, context) do
    params
    |> maybe_put_viewbox(context.bounds)
    |> maybe_put_bounded(context.bounded?, context.bounds)
    |> maybe_put_accept_language(context.accept_language)
    |> maybe_put_countrycodes(context.countrycodes)
  end

  @spec maybe_put_viewbox(keyword(), bounds() | nil) :: keyword()
  defp maybe_put_viewbox(params, nil), do: params

  defp maybe_put_viewbox(params, bounds) do
    Keyword.put(params, :viewbox, "#{bounds.west},#{bounds.north},#{bounds.east},#{bounds.south}")
  end

  @spec maybe_put_bounded(keyword(), boolean(), bounds() | nil) :: keyword()
  defp maybe_put_bounded(params, true, %{}), do: Keyword.put(params, :bounded, 1)
  defp maybe_put_bounded(params, _bounded?, _bounds), do: params

  @spec maybe_put_accept_language(keyword(), String.t() | nil) :: keyword()
  defp maybe_put_accept_language(params, nil), do: params

  defp maybe_put_accept_language(params, accept_language) do
    Keyword.put(params, :"accept-language", accept_language)
  end

  @spec maybe_put_countrycodes(keyword(), [String.t()] | nil) :: keyword()
  defp maybe_put_countrycodes(params, nil), do: params

  defp maybe_put_countrycodes(params, countrycodes) do
    Keyword.put(params, :countrycodes, Enum.join(countrycodes, ","))
  end

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

    if is_integer(limit) and limit in 1..40 do
      {:ok, limit}
    else
      {:error, :invalid_limit}
    end
  end

  @spec fetch_provider_context(search_opts()) ::
          {:ok, provider_context()}
          | {:error, :invalid_bounds | :invalid_accept_language | :invalid_countrycodes}
  defp fetch_provider_context(opts) do
    with {:ok, bounds} <- fetch_bounds(opts),
         {:ok, accept_language} <- fetch_accept_language(opts),
         {:ok, countrycodes} <- fetch_countrycodes(opts) do
      {:ok,
       %{
         bounds: bounds,
         bounded?: Keyword.get(opts, :bounded?, false),
         accept_language: accept_language,
         countrycodes: countrycodes
       }}
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

  @spec fetch_accept_language(search_opts()) ::
          {:ok, String.t() | nil} | {:error, :invalid_accept_language}
  defp fetch_accept_language(opts) do
    case Keyword.get(opts, :accept_language) do
      nil ->
        {:ok, nil}

      accept_language when is_binary(accept_language) ->
        accept_language
        |> String.trim()
        |> validate_accept_language()

      _accept_language ->
        {:error, :invalid_accept_language}
    end
  end

  @spec validate_accept_language(String.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_accept_language}
  defp validate_accept_language(""), do: {:ok, nil}

  defp validate_accept_language(accept_language) do
    if String.length(accept_language) <= 128 and
         Regex.match?(~r/\A[A-Za-z0-9*,;=._ -]+\z/, accept_language) do
      {:ok, accept_language}
    else
      {:error, :invalid_accept_language}
    end
  end

  @spec fetch_countrycodes(search_opts()) ::
          {:ok, [String.t()] | nil} | {:error, :invalid_countrycodes}
  defp fetch_countrycodes(opts) do
    case Keyword.get(opts, :countrycodes) do
      nil ->
        {:ok, nil}

      countrycodes when is_list(countrycodes) ->
        countrycodes
        |> Enum.map(&normalize_countrycode/1)
        |> validate_countrycodes()

      _countrycodes ->
        {:error, :invalid_countrycodes}
    end
  end

  @spec normalize_countrycode(term()) :: String.t() | :invalid
  defp normalize_countrycode(countrycode) when is_binary(countrycode) do
    countrycode
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_countrycode(_countrycode), do: :invalid

  @spec validate_countrycodes([String.t() | :invalid]) ::
          {:ok, [String.t()] | nil} | {:error, :invalid_countrycodes}
  defp validate_countrycodes(countrycodes) do
    unique_countrycodes = Enum.uniq(countrycodes)

    cond do
      unique_countrycodes == [] ->
        {:ok, nil}

      Enum.any?(unique_countrycodes, &(&1 == :invalid or not valid_countrycode?(&1))) ->
        {:error, :invalid_countrycodes}

      true ->
        {:ok, unique_countrycodes}
    end
  end

  @spec valid_countrycode?(String.t()) :: boolean()
  defp valid_countrycode?(<<a, b>>) do
    a in ?a..?z and b in ?a..?z
  end

  defp valid_countrycode?(_countrycode), do: false

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
