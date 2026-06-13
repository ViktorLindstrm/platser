defmodule Platser.MapSearchTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Events
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Search
  alias Platser.Map.Search.Geocoder
  alias Platser.Map.Search.Geocoder.Cache
  alias Platser.Map.Search.Result

  setup do
    Cache.clear()
    Req.Test.verify_on_exit!(Platser.Map.Search.Geocoder)
    :ok
  end

  describe "search_internal/4" do
    test "normalizes visible POI matches by name, description, and category" do
      user = create_user()
      event = create_event(user)

      poi =
        create_poi!(user, event, %{
          name: "North Camp",
          description: "Sheltered forest site",
          category: :camp,
          location: point(18.0, 59.0)
        })

      {:ok, [name_result]} = Search.search_internal(event.id, "north", user)
      assert_internal_result(name_result, poi, "Camp")

      {:ok, [description_result]} = Search.search_internal(event.id, "forest", user)
      assert_internal_result(description_result, poi, "Camp")

      {:ok, [category_result]} = Search.search_internal(event.id, "camp", user)
      assert_internal_result(category_result, poi, "Camp")
    end

    test "coordinate queries match nearby POIs and exclude distant POIs" do
      user = create_user()
      event = create_event(user)

      near =
        create_poi!(user, event, %{
          name: "Near marker",
          category: :viewpoint,
          location: point(18.0003, 59.0003)
        })

      _far =
        create_poi!(user, event, %{
          name: "Far marker",
          category: :viewpoint,
          location: point(18.5, 59.5)
        })

      {:ok, [result]} = Search.search_internal(event.id, "59.0000,18.0000", user)

      assert result.title == near.name
      assert result.distance_m in 0..1_000
      assert %Geo.Point{coordinates: {18.0003, 59.0003}, srid: 4326} = result.location
    end

    test "does not return POIs from another event" do
      user = create_user()
      current_event = create_event(user)
      other_event = create_event(user)

      current_poi =
        create_poi!(user, current_event, %{
          name: "Shared Camp",
          category: :camp,
          location: point(18.0, 59.0)
        })

      _other_poi =
        create_poi!(user, other_event, %{
          name: "Shared Camp",
          category: :camp,
          location: point(19.0, 60.0)
        })

      {:ok, results} = Search.search_internal(current_event.id, "shared", user)

      assert Enum.map(results, & &1.title) == [current_poi.name]
      assert Enum.map(results, & &1.id) == ["internal:poi:#{current_poi.id}"]
    end

    test "does not return public POIs to users outside the event" do
      admin = create_user()
      outsider = create_user()
      event = create_event(admin)

      admin
      |> create_poi!(event, %{
        name: "Public Event Camp",
        category: :camp,
        location: point(18.0, 59.0)
      })
      |> publish_poi!(admin)

      assert {:ok, []} = Search.search_internal(event.id, "camp", outsider)
    end

    test "respects POI draft visibility for event members, creators, and admins" do
      admin = create_user()
      member = create_user()
      event = create_event(admin)
      join_event!(member, event)

      draft =
        create_poi!(admin, event, %{
          name: "Hidden Draft Camp",
          category: :camp,
          location: point(18.0, 59.0)
        })

      public =
        admin
        |> create_poi!(event, %{
          name: "Public Camp",
          category: :camp,
          location: point(18.1, 59.1)
        })
        |> publish_poi!(admin)

      member_draft =
        create_poi!(member, event, %{
          name: "Member Draft Camp",
          category: :camp,
          location: point(18.2, 59.2)
        })

      assert {:ok, member_results} = Search.search_internal(event.id, "camp", member)
      assert result_titles(member_results) == ["Member Draft Camp", "Public Camp"]

      assert {:ok, admin_results} = Search.search_internal(event.id, "camp", admin)

      assert result_titles(admin_results) == [
               "Hidden Draft Camp",
               "Member Draft Camp",
               "Public Camp"
             ]

      assert {:ok, creator_results} = Search.search_internal(event.id, "hidden", admin)
      assert result_titles(creator_results) == [draft.name]

      assert {:ok, public_results} = Search.search_internal(event.id, "public", member)
      assert result_titles(public_results) == [public.name]

      assert {:ok, member_draft_results} =
               Search.search_internal(event.id, "member draft", member)

      assert result_titles(member_draft_results) == [member_draft.name]
    end
  end

  describe "parse_coordinates/1" do
    test "stores latitude longitude input as longitude latitude WGS84 points" do
      assert {:ok, %Geo.Point{coordinates: {18.12, 59.32}, srid: 4326}} =
               Search.parse_coordinates("59.32,18.12")
    end

    test "rejects out-of-range and non-strict coordinate input" do
      assert :error = Search.parse_coordinates("91,18")
      assert :error = Search.parse_coordinates("59,181")
      assert :error = Search.parse_coordinates("59.0,18.0,extra")
      assert :error = Search.parse_coordinates("59.0 north,18.0 east")
    end

    property "accepted coordinates are finite WGS84 points stored as longitude latitude" do
      check all(
              lat <- StreamData.float(min: -90.0, max: 90.0),
              lng <- StreamData.float(min: -180.0, max: 180.0),
              separator <- StreamData.member_of([",", ", ", " "]),
              max_runs: 50
            ) do
        assert {:ok, %Geo.Point{coordinates: {stored_lng, stored_lat}, srid: 4326}} =
                 Search.parse_coordinates("#{lat}#{separator}#{lng}")

        assert finite?(stored_lat)
        assert finite?(stored_lng)
        assert_in_delta stored_lat, lat, 0.0000001
        assert_in_delta stored_lng, lng, 0.0000001
      end
    end

    property "out-of-range coordinate-like input is rejected" do
      check all({lat, lng} <- invalid_coordinate_pair_gen(), max_runs: 50) do
        assert :error = Search.parse_coordinates("#{lat},#{lng}")
      end
    end
  end

  describe "search_external/2" do
    test "queries Nominatim search and normalizes external place results" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/search"
        assert conn.query_params["q"] == "central camp"
        assert conn.query_params["format"] == "jsonv2"
        assert conn.query_params["addressdetails"] == "1"
        assert conn.query_params["limit"] == "2"
        assert conn.query_params["viewbox"] == "17.9,59.4,18.2,59.1"
        assert conn.query_params["bounded"] == "1"

        Req.Test.json(conn, [
          %{
            "place_id" => 123,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Central Camp",
            "display_name" => "Central Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site",
            "boundingbox" => ["59.32", "59.34", "18.06", "18.08"],
            "address" => %{
              "road" => "Camp Road",
              "city" => "Stockholm",
              "country" => "Sweden"
            }
          }
        ])
      end)

      assert {:ok, [result]} =
               Search.search_external("central camp",
                 limit: 2,
                 bounds: %{west: 17.9, south: 59.1, east: 18.2, north: 59.4},
                 bounded?: true
               )

      assert %Result{} = result
      assert result.id == "external:nominatim:123"
      assert result.source == :external
      assert result.source_label == "Map"
      assert result.kind == :category
      assert result.kind_label == "Camp site"
      assert result.title == "Central Camp"
      assert result.subtitle == "Central Camp, Stockholm, Sweden"
      assert result.location == point(18.0686, 59.3293)
      assert result.bounds == %{west: 18.06, south: 59.32, east: 18.08, north: 59.34}
      assert result.category == "camp_site"
      assert result.address == "Camp Road, Stockholm, Sweden"
      assert result.provider == :nominatim
    end

    test "passes locale and explicit country filters to Nominatim search" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["accept-language"] == "sv-SE,sv;q=0.9,en;q=0.5"
        assert conn.query_params["countrycodes"] == "se,no"

        Req.Test.json(conn, [])
      end)

      assert {:ok, []} =
               Search.search_external("national park",
                 accept_language: "sv-SE,sv;q=0.9,en;q=0.5",
                 countrycodes: ["SE", "no", "se"]
               )
    end

    property "generated valid provider limits are accepted and sent to Nominatim" do
      check all(limit <- StreamData.integer(1..40), max_runs: 20) do
        Cache.clear()

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          assert conn.query_params["limit"] == Integer.to_string(limit)

          Req.Test.json(conn, [])
        end)

        assert {:ok, []} = Search.search_external("generated limit", limit: limit)
      end
    end

    property "generated invalid provider limits are rejected before provider requests" do
      check all(limit <- invalid_search_limit_gen(), max_runs: 20) do
        assert {:error, :invalid_limit} = Search.search_external("generated limit", limit: limit)
      end
    end

    property "valid bounds serialize to Nominatim viewbox west,north,east,south" do
      check all(bounds <- valid_bounds_gen(), max_runs: 20) do
        Cache.clear()

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          assert conn.query_params["viewbox"] ==
                   "#{bounds.west},#{bounds.north},#{bounds.east},#{bounds.south}"

          Req.Test.json(conn, [])
        end)

        assert {:ok, []} = Search.search_external("generated park", bounds: bounds)
      end
    end

    test "normalizes JSONv2 house-number payloads as address results" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["format"] == "jsonv2"

        Req.Test.json(conn, [
          %{
            "place_id" => 456,
            "lat" => "59.334",
            "lon" => "18.063",
            "name" => "12",
            "display_name" => "Drottninggatan 12, Stockholm, 111 51, Sweden",
            "category" => "place",
            "type" => "house",
            "addresstype" => "house",
            "address" => %{
              "house_number" => "12",
              "road" => "Drottninggatan",
              "city" => "Stockholm",
              "postcode" => "111 51",
              "country" => "Sweden",
              "country_code" => "se",
              "ISO3166-2-lvl4" => "SE-AB"
            }
          }
        ])
      end)

      assert {:ok, [result]} = Search.search_external("drottninggatan 12")

      assert result.kind == :address
      assert result.kind_label == "Address"
      assert result.title == "Drottninggatan 12"
      assert result.category == "house"
      assert result.address == "Drottninggatan 12, Stockholm, 111 51, Sweden"
      refute String.contains?(result.address, "country_code")
      refute String.contains?(result.address, "ISO3166")
      refute String.contains?(result.address, "se")
    end

    test "uses the street address as the title when provider name is only a house number" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 457,
            "lat" => "59.334",
            "lon" => "18.063",
            "name" => "2",
            "display_name" => "2, Hövägen, Teststad, Sweden",
            "category" => "place",
            "type" => "house",
            "addresstype" => "house",
            "address" => %{
              "house_number" => "2",
              "road" => "Hövägen",
              "city" => "Teststad",
              "country" => "Sweden"
            }
          }
        ])
      end)

      assert {:ok, [result]} = Search.search_external("hövägen 2")

      assert result.kind == :address
      assert result.title == "Hövägen 2"
      assert result.address == "Hövägen 2, Teststad, Sweden"
    end

    test "uses display name street context for address results without structured address parts" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 458,
            "lat" => "59.334",
            "lon" => "18.063",
            "name" => "2",
            "display_name" => "2, Hövägen, Teststad, Sweden",
            "category" => "place",
            "type" => "house",
            "addresstype" => "house"
          }
        ])
      end)

      assert {:ok, [result]} = Search.search_external("hövägen 2")

      assert result.kind == :address
      assert result.title == "Hövägen 2"
      assert result.address == "2, Hövägen, Teststad, Sweden"
    end

    test "normalizes mixed JSON and JSONv2 provider classification fields" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 501,
            "lat" => "59.33",
            "lon" => "18.07",
            "name" => "Lunch Place",
            "category" => "amenity",
            "type" => "restaurant"
          },
          %{
            "place_id" => 502,
            "lat" => "59.34",
            "lon" => "18.08",
            "name" => "Old Camp",
            "class" => "tourism",
            "type" => "camp_site"
          },
          %{
            "place_id" => 503,
            "lat" => "59.35",
            "lon" => "18.09",
            "display_name" => "111 51, Stockholm, Sweden",
            "type" => "postcode",
            "addresstype" => "postcode",
            "address" => %{
              "postcode" => "111 51",
              "city" => "Stockholm",
              "country" => "Sweden"
            }
          }
        ])
      end)

      assert {:ok, [restaurant, camp, postcode]} = Search.search_external("mixed")

      assert restaurant.kind == :category
      assert restaurant.kind_label == "Restaurant"
      assert camp.kind == :category
      assert camp.kind_label == "Camp site"
      assert postcode.kind == :address
      assert postcode.kind_label == "Address"
      assert postcode.address == "Stockholm, 111 51, Sweden"
    end

    test "retries address-like searches with structured street params when free-form is empty" do
      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params do
          %{"q" => "hövägen 7"} ->
            refute Map.has_key?(conn.query_params, "street")
            refute Map.has_key?(conn.query_params, "bounded")
            Req.Test.json(conn, [])

          %{"street" => "hövägen 7"} ->
            refute Map.has_key?(conn.query_params, "q")
            refute Map.has_key?(conn.query_params, "bounded")
            assert conn.query_params["format"] == "jsonv2"
            assert conn.query_params["addressdetails"] == "1"
            assert conn.query_params["limit"] == "5"

            Req.Test.json(conn, [
              %{
                "place_id" => 777,
                "lat" => "59.1",
                "lon" => "18.2",
                "display_name" => "Hövägen 7, Teststad, Sweden",
                "category" => "place",
                "type" => "house",
                "addresstype" => "house",
                "address" => %{
                  "house_number" => "7",
                  "road" => "Hövägen",
                  "city" => "Teststad",
                  "country" => "Sweden"
                }
              }
            ])
        end
      end)

      assert {:ok, [result]} = Search.search_external("hövägen 7")
      assert result.id == "external:nominatim:777"
      assert result.kind == :address
      assert result.kind_label == "Address"
      assert result.address == "Hövägen 7, Teststad, Sweden"
    end

    test "retries address-like searches when free-form returns weak global results" do
      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params do
          %{"q" => "hövägen 7"} ->
            Req.Test.json(conn, [
              %{
                "place_id" => 700,
                "lat" => "1.0",
                "lon" => "2.0",
                "name" => "7",
                "display_name" => "7",
                "category" => "place",
                "type" => "number"
              }
            ])

          %{"street" => "hövägen 7"} ->
            Req.Test.json(conn, [
              %{
                "place_id" => 701,
                "lat" => "59.1",
                "lon" => "18.2",
                "display_name" => "Hövägen 7, Teststad, Sweden",
                "category" => "place",
                "type" => "house",
                "addresstype" => "house",
                "address" => %{
                  "house_number" => "7",
                  "road" => "Hövägen",
                  "city" => "Teststad",
                  "country" => "Sweden"
                }
              }
            ])
        end
      end)

      assert {:ok, [structured, weak]} = Search.search_external("hövägen 7")
      assert structured.id == "external:nominatim:701"
      assert structured.kind == :address
      assert weak.id == "external:nominatim:700"
    end

    test "preserves free-form results when they already contain a useful address match" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["q"] == "hövägen 7"
        refute Map.has_key?(conn.query_params, "street")

        Req.Test.json(conn, [
          %{
            "place_id" => 702,
            "lat" => "59.1",
            "lon" => "18.2",
            "display_name" => "Hövägen 7, Teststad, Sweden",
            "category" => "place",
            "type" => "house",
            "addresstype" => "house",
            "address" => %{
              "house_number" => "7",
              "road" => "Hövägen",
              "city" => "Teststad",
              "country" => "Sweden"
            }
          }
        ])
      end)

      assert {:ok, [result]} = Search.search_external("hövägen 7")
      assert result.id == "external:nominatim:702"
      assert result.address == "Hövägen 7, Teststad, Sweden"
    end

    test "keeps structured retry scoped to the existing viewbox bias" do
      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["viewbox"] == "17.9,59.4,18.2,59.1"

        case conn.query_params do
          %{"q" => "hövägen 7"} ->
            Req.Test.json(conn, [])

          %{"street" => "hövägen 7"} ->
            refute Map.has_key?(conn.query_params, "q")
            assert conn.query_params["bounded"] == "1"
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, []} =
               Search.search_external("hövägen 7",
                 bounds: %{west: 17.9, south: 59.1, east: 18.2, north: 59.4}
               )
    end

    test "drops weak global results when bounded structured retry finds no local address" do
      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params do
          %{"q" => "hövägen 7"} ->
            Req.Test.json(conn, [
              %{
                "place_id" => 800,
                "lat" => "60.281",
                "lon" => "25.028",
                "name" => "7",
                "display_name" => "7, Heinätie, Helsinki, Suomi / Finland",
                "category" => "place",
                "type" => "house",
                "addresstype" => "house",
                "address" => %{
                  "house_number" => "7",
                  "road" => "Heinätie",
                  "city" => "Helsinki",
                  "country" => "Suomi / Finland"
                }
              }
            ])

          %{"street" => "hövägen 7"} ->
            assert conn.query_params["bounded"] == "1"
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, []} =
               Search.search_external("hövägen 7",
                 bounds: %{west: 17.9, south: 59.1, east: 18.2, north: 59.4}
               )
    end

    property "accepted provider payloads normalize to safe finite external results" do
      check all(payload <- provider_payload_gen(), max_runs: 20) do
        Cache.clear()

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          Req.Test.json(conn, [payload])
        end)

        assert {:ok, [result]} = Search.search_external("generated place")

        assert result.source == :external
        assert result.source_label == "Map"
        assert result.provider == :nominatim
        assert result.id =~ "external:nominatim:"
        assert is_binary(result.title)
        assert String.trim(result.title) != ""
        assert is_binary(result.kind_label)
        assert String.trim(result.kind_label) != ""
        assert %Geo.Point{coordinates: {lng, lat}, srid: 4326} = result.location
        assert finite?(lat)
        assert finite?(lng)
        assert lat >= -90.0 and lat <= 90.0
        assert lng >= -180.0 and lng <= 180.0

        if result.address do
          refute String.contains?(result.address, "country_code")
          refute String.contains?(result.address, "ISO3166")
          refute String.contains?(result.address, "raw-metadata")
        end
      end
    end

    property "structured address retries never combine q with structured params" do
      check all(query <- structured_address_query_gen(), max_runs: 20) do
        Cache.clear()

        Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          if Map.has_key?(conn.query_params, "q") do
            refute Map.has_key?(conn.query_params, "street")
          else
            assert Map.has_key?(conn.query_params, "street")
            refute Map.has_key?(conn.query_params, "q")
            assert String.length(conn.query_params["street"]) <= 120
          end

          Req.Test.json(conn, [])
        end)

        assert {:ok, []} = Search.search_external(query)
      end
    end

    test "category-only searches map known app categories to provider query text" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/search"
        assert conn.query_params["q"] == "restaurant"

        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Search.search_external("", category: :food)
    end

    test "coordinate input calls reverse and returns a coordinate result with address context" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/reverse"
        assert conn.query_params["lat"] == "59.3293"
        assert conn.query_params["lon"] == "18.0686"

        Req.Test.json(conn, %{
          "display_name" => "Sergels torg, Stockholm, Sweden",
          "address" => %{"square" => "Sergels torg", "city" => "Stockholm", "country" => "Sweden"},
          "class" => "place",
          "type" => "square"
        })
      end)

      assert {:ok, [result]} = Search.search_external("59.3293,18.0686")

      assert result.id == "external:nominatim:coordinate:59.3293,18.0686"
      assert result.kind == :coordinate
      assert result.kind_label == "Coordinates"
      assert result.title == "Sergels torg, Stockholm, Sweden"
      assert result.subtitle == "59.3293, 18.0686"
      assert result.location == point(18.0686, 59.3293)
      assert result.address == "Sergels torg, Stockholm, Sweden"
    end

    test "can normalize coordinate input without reverse lookup" do
      assert {:ok, [result]} = Search.search_external("59.3293,18.0686", reverse?: false)

      assert result.kind == :coordinate
      assert result.title == "59.3293, 18.0686"
      assert result.location == point(18.0686, 59.3293)
    end

    test "empty provider responses are successful empty results" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Search.search_external("missing place")
    end

    test "cache falls back to the uncached function when the process is unavailable" do
      cache_pid = Process.whereis(Cache)
      assert is_pid(cache_pid)

      Process.unregister(Cache)

      try do
        assert {:ok, :fresh_result} =
                 Cache.fetch(Cache.key(%{query: "missing process"}), fn ->
                   {:ok, :fresh_result}
                 end)

        assert :ok = Cache.clear()
      after
        if Process.whereis(Cache) == nil and Process.alive?(cache_pid) do
          Process.register(cache_pid, Cache)
        end
      end
    end

    test "repeated identical external searches use the normalized server-side cache" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 901,
            "lat" => "59.33",
            "lon" => "18.07",
            "name" => "Cached Camp",
            "category" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      assert {:ok, [first]} = Search.search_external("cached camp", limit: 5)
      assert {:ok, [second]} = Search.search_external(" cached camp ", limit: 5)
      assert first.id == "external:nominatim:901"
      assert second.id == first.id
    end

    test "cache misses are separated by material provider request params" do
      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        place_id = String.to_integer(conn.query_params["limit"]) + 1_000

        Req.Test.json(conn, [
          %{
            "place_id" => place_id,
            "lat" => "59.33",
            "lon" => "18.07",
            "name" => "Limit #{conn.query_params["limit"]}",
            "category" => "place",
            "type" => "neighbourhood"
          }
        ])
      end)

      assert {:ok, [limited]} = Search.search_external("cache separated", limit: 5)
      assert {:ok, [expanded]} = Search.search_external("cache separated", limit: 15)
      assert limited.id == "external:nominatim:1005"
      assert expanded.id == "external:nominatim:1015"
    end

    test "expired entries miss the cache and failures are not cached" do
      old_ttl = Application.get_env(:platser, :geocoder_cache_ttl_ms)
      Application.put_env(:platser, :geocoder_cache_ttl_ms, 0)

      on_exit(fn ->
        Application.put_env(:platser, :geocoder_cache_ttl_ms, old_ttl)
      end)

      Req.Test.expect(Platser.Map.Search.Geocoder, 4, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["q"] do
          "expiring camp" ->
            Req.Test.json(conn, [
              %{
                "place_id" => System.unique_integer([:positive]),
                "lat" => "59.33",
                "lon" => "18.07",
                "name" => "Expiring Camp",
                "category" => "place",
                "type" => "neighbourhood"
              }
            ])

          "limited once" ->
            Plug.Conn.send_resp(conn, 429, "too many requests")
        end
      end)

      assert {:ok, [_first]} = Search.search_external("expiring camp")
      assert {:ok, [_second]} = Search.search_external("expiring camp")
      assert {:error, :provider_rate_limited} = Search.search_external("limited once")
      assert {:error, :provider_rate_limited} = Search.search_external("limited once")
    end

    test "cache evicts the oldest entry when the configured maximum is exceeded" do
      old_max_entries = Application.get_env(:platser, :geocoder_cache_max_entries)
      Application.put_env(:platser, :geocoder_cache_max_entries, 1)

      on_exit(fn ->
        Application.put_env(:platser, :geocoder_cache_max_entries, old_max_entries)
      end)

      Req.Test.expect(Platser.Map.Search.Geocoder, 3, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        Req.Test.json(conn, [
          %{
            "place_id" => "cache-#{conn.query_params["q"]}",
            "lat" => "59.33",
            "lon" => "18.07",
            "name" => "Cache #{conn.query_params["q"]}",
            "category" => "place",
            "type" => "neighbourhood"
          }
        ])
      end)

      assert {:ok, [first]} = Search.search_external("first bounded cache")
      assert {:ok, [second]} = Search.search_external("second bounded cache")
      assert {:ok, [first_again]} = Search.search_external("first bounded cache")

      assert first.id == first_again.id
      refute first.id == second.id
    end

    test "normalizes malformed provider responses" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, :malformed_response} = Search.search_external("broken")
    end

    test "normalizes malformed result coordinates" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 123,
            "lat" => "not-a-number",
            "lon" => "18.0686",
            "display_name" => "Broken place"
          }
        ])
      end)

      assert {:error, :malformed_response} = Search.search_external("broken")
    end

    test "normalizes rate-limit and transport errors" do
      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Plug.Conn.send_resp(conn, 429, "too many requests")
      end)

      assert {:error, :provider_rate_limited} = Search.search_external("limited")

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :provider_timeout} = Search.search_external("timeout")
    end

    test "rejects invalid input and unsupported bounded searches" do
      assert {:error, :invalid_query} = Search.search_external("   ")
      assert {:error, :invalid_limit} = Search.search_external("stockholm", limit: 0)

      assert {:error, :invalid_bounds} =
               Search.search_external("stockholm",
                 bounds: %{west: 181.0, south: 0.0, east: 1.0, north: 1.0}
               )

      assert {:error, :unsupported} = Search.search_external("stockholm", bounded?: true)
      assert {:error, :invalid_query} = Search.search_external("", category: :unknown)

      assert {:error, :invalid_accept_language} =
               Search.search_external("stockholm", accept_language: "<script>")

      assert {:error, :invalid_countrycodes} =
               Search.search_external("stockholm", countrycodes: ["swe"])
    end

    property "generated invalid bounds are rejected before provider requests" do
      check all(bounds <- invalid_bounds_gen(), max_runs: 20) do
        assert {:error, :invalid_bounds} =
                 Search.search_external("generated park", bounds: bounds)
      end
    end

    property "equivalent normalized inputs map to the same cache key" do
      check all(query <- safe_query_gen(), max_runs: 20) do
        assert {:ok, first_key} = Geocoder.cache_key("  #{query}  ", limit: 5)
        assert {:ok, second_key} = Geocoder.cache_key(query, limit: 5)
        assert first_key == second_key
      end
    end

    property "materially different params map to different cache keys without creating atoms" do
      check all(
              query <- safe_query_gen(),
              bounds <- valid_bounds_gen(),
              max_runs: 20
            ) do
        before_atoms = :erlang.system_info(:atom_count)

        assert {:ok, base_key} = Geocoder.cache_key(query, limit: 5)

        assert {:ok, bounded_key} =
                 Geocoder.cache_key(query,
                   limit: 5,
                   bounds: bounds,
                   accept_language: "sv-SE",
                   countrycodes: ["SE"]
                 )

        assert {:ok, expanded_key} = Geocoder.cache_key(query, limit: 15)
        refute base_key == bounded_key
        refute base_key == expanded_key
        assert :erlang.system_info(:atom_count) == before_atoms
      end
    end
  end

  @spec create_user() :: Platser.Accounts.User.t()
  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "map_search_#{n}@example.com",
          display_name: "Map Search User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(Platser.Accounts.User.t()) :: Platser.Events.Event.t()
  defp create_event(user) do
    {:ok, event} =
      Events.create_event(
        %{
          name: "Search Test Event",
          description: "Search test event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  @spec join_event!(Platser.Accounts.User.t(), Platser.Events.Event.t()) ::
          Platser.Events.Membership.t()
  defp join_event!(user, event) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec create_poi!(Platser.Accounts.User.t(), Platser.Events.Event.t(), map()) ::
          Platser.Map.Poi.t()
  defp create_poi!(user, event, attrs) do
    {:ok, poi} =
      PlatserMap.create_poi(
        Map.merge(
          %{
            name: "Search POI",
            category: :other,
            location: point(18.0, 59.0),
            event_id: event.id
          },
          attrs
        ),
        actor: user
      )

    poi
  end

  @spec publish_poi!(Platser.Map.Poi.t(), Platser.Accounts.User.t()) :: Platser.Map.Poi.t()
  defp publish_poi!(poi, user) do
    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    published
  end

  @spec point(float(), float()) :: Geo.Point.t()
  defp point(lng, lat), do: %Geo.Point{coordinates: {lng, lat}, srid: 4326}

  @spec finite?(float()) :: boolean()
  defp finite?(value), do: value == value and value - value == 0.0

  @spec invalid_search_limit_gen() :: StreamData.t(integer())
  defp invalid_search_limit_gen do
    StreamData.one_of([
      StreamData.integer(-20..0),
      StreamData.integer(41..120)
    ])
  end

  @spec safe_query_gen() :: StreamData.t(String.t())
  defp safe_query_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 32)
    |> StreamData.map(&String.trim/1)
    |> StreamData.filter(&(&1 != ""))
  end

  @spec invalid_coordinate_pair_gen() :: StreamData.t({float(), float()})
  defp invalid_coordinate_pair_gen do
    StreamData.one_of([
      StreamData.tuple({
        StreamData.one_of([
          StreamData.float(min: -1_000.0, max: -90.0001),
          StreamData.float(min: 90.0001, max: 1_000.0)
        ]),
        StreamData.float(min: -180.0, max: 180.0)
      }),
      StreamData.tuple({
        StreamData.float(min: -90.0, max: 90.0),
        StreamData.one_of([
          StreamData.float(min: -1_000.0, max: -180.0001),
          StreamData.float(min: 180.0001, max: 1_000.0)
        ])
      })
    ])
  end

  @spec valid_bounds_gen() :: StreamData.t(Result.bounds())
  defp valid_bounds_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.float(min: -179.0, max: 179.0),
        StreamData.float(min: -89.0, max: 89.0),
        StreamData.float(min: 0.01, max: 1.0),
        StreamData.float(min: 0.01, max: 1.0)
      }),
      fn {west, south, lng_delta, lat_delta} ->
        StreamData.constant(%{
          west: west,
          south: south,
          east: min(west + lng_delta, 180.0),
          north: min(south + lat_delta, 90.0)
        })
      end
    )
  end

  @spec invalid_bounds_gen() :: StreamData.t(map())
  defp invalid_bounds_gen do
    StreamData.one_of([
      StreamData.map(
        StreamData.tuple({
          StreamData.float(min: -180.0, max: 180.0),
          StreamData.float(min: -90.0, max: 90.0)
        }),
        fn {west, south} ->
          %{west: west, south: south, east: west - 0.01, north: south + 0.01}
        end
      ),
      StreamData.map(
        StreamData.tuple({
          StreamData.float(min: -180.0, max: 180.0),
          StreamData.float(min: -90.0, max: 90.0)
        }),
        fn {west, south} ->
          %{west: west, south: south, east: west + 0.01, north: south - 0.01}
        end
      ),
      StreamData.constant(%{west: 181.0, south: 0.0, east: 182.0, north: 1.0}),
      StreamData.constant(%{west: 0.0, south: -91.0, east: 1.0, north: -90.0})
    ])
  end

  @spec structured_address_query_gen() :: StreamData.t(String.t())
  defp structured_address_query_gen do
    StreamData.bind(street_name_gen(), fn street ->
      StreamData.bind(StreamData.integer(1..999), fn house_number ->
        StreamData.member_of([
          "#{street} #{house_number}",
          "#{house_number} #{street}",
          "#{street} #{house_number}, Teststad",
          "#{street} #{house_number}, 123 45",
          "123 45, #{street} #{house_number}"
        ])
      end)
    end)
  end

  @spec street_name_gen() :: StreamData.t(String.t())
  defp street_name_gen do
    StreamData.member_of(["Hövägen", "Drottninggatan", "Generated Road", "Storgatan"])
  end

  @spec provider_payload_gen() :: StreamData.t(map())
  defp provider_payload_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.integer(1..1_000_000),
        StreamData.float(min: -90.0, max: 90.0),
        StreamData.float(min: -180.0, max: 180.0),
        provider_shape_gen()
      }),
      fn {place_id, lat, lng, shape} ->
        StreamData.constant(provider_payload(place_id, lat, lng, shape))
      end
    )
  end

  @spec provider_shape_gen() :: StreamData.t(atom())
  defp provider_shape_gen do
    StreamData.member_of([:jsonv2_house, :jsonv2_restaurant, :json_camp, :postcode])
  end

  @spec provider_payload(pos_integer(), float(), float(), atom()) :: map()
  defp provider_payload(place_id, lat, lng, :jsonv2_house) do
    %{
      "place_id" => place_id,
      "lat" => Float.to_string(lat),
      "lon" => Float.to_string(lng),
      "display_name" => "Generated Road 7, Test City, Sweden",
      "category" => "place",
      "type" => "house",
      "addresstype" => "house",
      "address" => generated_address("7")
    }
  end

  defp provider_payload(place_id, lat, lng, :jsonv2_restaurant) do
    %{
      "place_id" => place_id,
      "lat" => Float.to_string(lat),
      "lon" => Float.to_string(lng),
      "name" => "Generated Restaurant",
      "category" => "amenity",
      "type" => "restaurant",
      "address" => generated_address(nil)
    }
  end

  defp provider_payload(place_id, lat, lng, :json_camp) do
    %{
      "place_id" => place_id,
      "lat" => Float.to_string(lat),
      "lon" => Float.to_string(lng),
      "name" => "Generated Camp",
      "class" => "tourism",
      "type" => "camp_site",
      "address" => generated_address(nil)
    }
  end

  defp provider_payload(place_id, lat, lng, :postcode) do
    %{
      "place_id" => place_id,
      "lat" => Float.to_string(lat),
      "lon" => Float.to_string(lng),
      "display_name" => "123 45, Test City, Sweden",
      "type" => "postcode",
      "addresstype" => "postcode",
      "address" => %{
        "postcode" => "123 45",
        "city" => "Test City",
        "country" => "Sweden",
        "country_code" => "raw-metadata",
        "ISO3166-2-lvl4" => "raw-metadata"
      }
    }
  end

  @spec generated_address(String.t() | nil) :: map()
  defp generated_address(house_number) do
    %{
      "house_number" => house_number,
      "road" => "Generated Road",
      "city" => "Test City",
      "postcode" => "123 45",
      "country" => "Sweden",
      "country_code" => "raw-metadata",
      "ISO3166-2-lvl4" => "raw-metadata"
    }
  end

  @spec assert_internal_result(Result.t(), Platser.Map.Poi.t(), String.t()) :: true
  defp assert_internal_result(result, poi, kind_label) do
    assert %Result{} = result
    assert result.id == "internal:poi:#{poi.id}"
    assert result.source == :internal
    assert result.source_label == "Event POI"
    assert result.kind == :poi
    assert result.kind_label == kind_label
    assert result.title == poi.name
    assert result.location == poi.location
  end

  @spec result_titles([Result.t()]) :: [String.t()]
  defp result_titles(results) do
    results
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end
end
