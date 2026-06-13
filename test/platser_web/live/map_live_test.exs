defmodule PlatserWeb.MapLiveTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Activity
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Search.Geocoder.Cache
  alias Platser.Media

  setup do
    Cache.clear()
    Req.Test.verify_on_exit!(Platser.Map.Search.Geocoder)
    :ok
  end

  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: String.capitalize("#{tag} #{n}"),
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(Platser.Accounts.User, :password),
        :sign_in,
        %{email: user.email, password: "password123"},
        authorize?: false
      )

    signed_in_user
  end

  defp sign_in_conn(conn, user) do
    signed_in_conn =
      conn
      |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
      |> init_test_session(%{})
      |> PlatserWeb.AuthController.success(%{}, user, user.__metadata__.token)

    Phoenix.ConnTest.build_conn()
    |> put_private(:phoenix_endpoint, PlatserWeb.Endpoint)
    |> init_test_session(Map.get(signed_in_conn.private, :plug_session, %{}))
  end

  defp create_event(user) do
    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Map Live Test",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  defp create_poi(user, event) do
    create_poi(user, event, %{})
  end

  defp create_poi(user, event, attrs) do
    params =
      Map.merge(
        %{
          name: "Inspection POI",
          description: "A draft POI for inspection",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {174.7633, -36.8485}, srid: 4326},
          event_id: event.id
        },
        attrs
      )

    {:ok, poi} =
      PlatserMap.create_poi(
        params,
        actor: user
      )

    poi
  end

  defp list_event_pois(user, event) do
    {:ok, pois} = PlatserMap.list_pois_for_event(event.id, actor: user)
    pois
  end

  defp create_geofence(user, event) do
    {:ok, geofence} =
      PlatserMap.create_geofence(
        %{
          name: "Inspection Geofence",
          purpose: :boundary,
          color: "#3B82F6",
          geometry: %Geo.Polygon{
            coordinates: [
              [
                {174.7600, -36.8500},
                {174.7700, -36.8500},
                {174.7700, -36.8400},
                {174.7600, -36.8400},
                {174.7600, -36.8500}
              ]
            ],
            srid: 4326
          },
          event_id: event.id
        },
        actor: user
      )

    geofence
  end

  defp create_attachment(user, poi) do
    stored_filename = "#{Ecto.UUID.generate()}.jpg"

    {:ok, attachment} =
      Media.create_attachment(
        %{
          filename: "image.jpg",
          stored_filename: stored_filename,
          content_type: "image/jpeg",
          path: "/uploads/#{poi.id}/#{stored_filename}",
          poi_id: poi.id
        },
        actor: user,
        authorize?: false
      )

    attachment
  end

  defp insert_activity_entry(user, event, action, subject_id) do
    {:ok, entry} =
      Activity.create_entry(
        %{
          action: action,
          subject_type: "poi",
          subject_id: subject_id,
          message: "Seeded #{action}",
          event_id: event.id
        },
        actor: user,
        authorize?: false
      )

    entry
  end

  describe "map search UI (task #78)" do
    test "renders the search form at the top of the map", %{conn: conn} do
      user = create_user("search_render")
      event = create_event(user)
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      assert has_element?(view, "#map-search-panel")
      assert has_element?(view, "#map-search-form")
      assert has_element?(view, "#map-search-input")
      assert has_element?(view, "#map-search-submit")
      assert has_element?(view, "#map-search-collapse-toggle")
      assert has_element?(view, "#map-search-viewport-west")
      assert has_element?(view, "#map-search-viewport-south")
      assert has_element?(view, "#map-search-viewport-east")
      assert has_element?(view, "#map-search-viewport-north")
      refute has_element?(view, "#map-search-results")
    end

    test "search shows internal and external results with source labels", %{conn: conn} do
      user = create_user("search_results")
      event = create_event(user)

      poi =
        create_poi(user, event, %{
          name: "North Camp",
          description: "Sheltered forest camp",
          category: :camp,
          location: %Geo.Point{coordinates: {18.0, 59.0}, srid: 4326}
        })

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 321,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Central Camp",
            "display_name" => "Central Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "camp"}
      })

      assert has_element?(view, "#map-search-results")
      assert has_element?(view, "#map-search-result-internal-poi-#{poi.id}", "Event POI")
      assert has_element?(view, "#map-search-result-external-nominatim-321", "Map")
    end

    test "address search result heading shows street and number, not only house number",
         %{conn: conn} do
      user = create_user("search_address_heading")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 166_162_271,
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

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "hövägen 2"}
      })

      assert has_element?(
               view,
               "#map-search-result-external-nominatim-166162271 h2",
               "Hövägen 2"
             )
    end

    property "external search result badges render normalized labels with stable DOM IDs" do
      check all(
              {place_id, payload, expected_label} <- map_search_provider_payload_gen(),
              max_runs: 5
            ) do
        Cache.clear()

        user = create_user("search_label_prop")
        event = create_event(user)

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          Req.Test.json(conn, [payload])
        end)

        conn = sign_in_conn(build_conn(), user)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_submit(element(view, "#map-search-form"), %{
          "search" => %{"query" => "generated"}
        })

        result_id = "#map-search-result-external-nominatim-#{place_id}"

        assert has_element?(view, "#map-search-results")
        assert has_element?(view, result_id, "Map")
        assert has_element?(view, result_id, expected_label)
      end
    end

    property "search submit uses generated viewport bounds as provider viewbox" do
      check all(
              bounds <- map_search_viewport_bounds_gen(),
              place_id <- StreamData.integer(20_000..29_999),
              max_runs: 5
            ) do
        Cache.clear()

        user = create_user("search_viewport_prop")
        event = create_event(user)

        create_poi(user, event, %{
          name: "Fallback POI",
          location: %Geo.Point{coordinates: {174.7633, -36.8485}, srid: 4326}
        })

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          assert conn.query_params["viewbox"] ==
                   "#{bounds.west},#{bounds.north},#{bounds.east},#{bounds.south}"

          Req.Test.json(conn, [
            %{
              "place_id" => place_id,
              "lat" => "#{(bounds.south + bounds.north) / 2}",
              "lon" => "#{(bounds.west + bounds.east) / 2}",
              "name" => "Viewport Result",
              "category" => "place",
              "type" => "neighbourhood"
            }
          ])
        end)

        conn = sign_in_conn(build_conn(), user)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_submit(element(view, "#map-search-form"), %{
          "search" => %{
            "query" => "viewport result",
            "viewport_west" => "#{bounds.west}",
            "viewport_south" => "#{bounds.south}",
            "viewport_east" => "#{bounds.east}",
            "viewport_north" => "#{bounds.north}"
          }
        })

        assert has_element?(view, "#map-search-form")
        assert has_element?(view, "#map-search-input")
        assert has_element?(view, "#map-search-result-external-nominatim-#{place_id}")
      end
    end

    test "invalid submitted viewport bounds fall back to event object bounds", %{conn: conn} do
      user = create_user("search_viewport_invalid")
      event = create_event(user)

      create_poi(user, event, %{
        name: "Fallback POI",
        location: %Geo.Point{coordinates: {18.0, 59.0}, srid: 4326}
      })

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["viewbox"] == "18.0,59.0,18.0,59.0"

        Req.Test.json(conn, [])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{
          "query" => "fallback result",
          "viewport_west" => "190",
          "viewport_south" => "59",
          "viewport_east" => "18",
          "viewport_north" => "60"
        }
      })

      assert has_element?(view, "#map-search-form")
      assert has_element?(view, "#map-search-input")
      assert has_element?(view, "#map-search-no-results")
    end

    test "clearing the search input clears visible results but keeps the temporary pin selected",
         %{conn: conn} do
      user = create_user("search_clear_results")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 432,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Clearable Camp",
            "display_name" => "Clearable Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "clearable camp"}
      })

      assert has_element?(view, "#map-search-results")
      assert has_element?(view, "#map-search-result-external-nominatim-432")

      render_click(element(view, "#map-search-result-external-nominatim-432"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:432"})

      render_change(element(view, "#map-search-form"), %{
        "search" => %{"query" => ""}
      })

      refute has_element?(view, "#map-search-results")
      refute has_element?(view, "#map-search-result-external-nominatim-432")

      render_hook(view, "create_poi_from_search_result", %{})

      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert has_element?(view, ~s(#poi-name[value="Clearable Camp"]))
      assert has_element?(view, "#poi-form", "59.32930, 18.06860")
    end

    test "search shows a clear no-results state", %{conn: conn} do
      user = create_user("search_empty")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "not a real place"}
      })

      assert has_element?(view, "#map-search-results")
      assert has_element?(view, "#map-search-no-results")
    end

    test "search caps rendered rows and can explicitly load more results", %{conn: conn} do
      user = create_user("search_more")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        limit = String.to_integer(conn.query_params["limit"])

        Req.Test.json(conn, map_search_payloads(limit))
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "generated more"}
      })

      assert has_element?(view, "#map-search-results")
      assert has_element?(view, "#map-search-result-external-nominatim-9001")
      assert has_element?(view, "#map-search-result-external-nominatim-9005")
      refute has_element?(view, "#map-search-result-external-nominatim-9006")
      assert has_element?(view, "#map-search-more-results")

      render_click(element(view, "#map-search-result-external-nominatim-9003"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:9003"})

      render_click(element(view, "#map-search-more-results"))

      assert has_element?(view, "#map-search-result-external-nominatim-9001")
      assert has_element?(view, "#map-search-result-external-nominatim-9015")
      refute has_element?(view, "#map-search-result-external-nominatim-9016")
      assert has_element?(view, "#map-search-more-results")

      render_hook(view, "create_poi_from_search_result", %{})

      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert has_element?(view, ~s(#poi-name[value="Generated Result 3"]))
    end

    property "generated search result lists render stable capped rows and empty states" do
      check all(result_count <- StreamData.integer(0..12), max_runs: 5) do
        Cache.clear()

        user = create_user("search_volume_prop")
        event = create_event(user)

        Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
          Req.Test.json(conn, map_search_payloads(result_count))
        end)

        conn = sign_in_conn(build_conn(), user)
        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_submit(element(view, "#map-search-form"), %{
          "search" => %{"query" => "generated volume"}
        })

        assert has_element?(view, "#map-search-results")

        if result_count == 0 do
          assert has_element?(view, "#map-search-no-results")
          refute has_element?(view, "#map-search-more-results")
        else
          visible_count = min(result_count, 5)

          assert has_element?(
                   view,
                   "#map-search-result-external-nominatim-#{9000 + visible_count}"
                 )

          refute has_element?(
                   view,
                   "#map-search-result-external-nominatim-#{9000 + visible_count + 1}"
                 )

          if result_count >= 5 do
            assert has_element?(view, "#map-search-more-results")
          else
            refute has_element?(view, "#map-search-more-results")
          end
        end
      end
    end

    test "search failures show an error flash", %{conn: conn} do
      user = create_user("search_error")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Plug.Conn.send_resp(conn, 429, "too many requests")
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "limited place"}
      })

      assert has_element?(view, "#flash-error", "Map search is busy. Try again soon.")
    end

    test "search can be collapsed and expanded without clearing the temporary pin", %{conn: conn} do
      user = create_user("search_collapse")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 765,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Collapsible Camp",
            "display_name" => "Collapsible Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "collapsible camp"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-765"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:765"})

      render_click(element(view, "#map-search-collapse-toggle"))

      refute has_element?(view, "#map-search-form")
      assert has_element?(view, "#map-search-expand-toggle")

      render_hook(view, "create_poi_from_search_result", %{})

      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert has_element?(view, ~s(#poi-name[value="Collapsible Camp"]))
      assert has_element?(view, "#poi-form", "59.32930, 18.06860")
    end

    test "selecting an external result pushes a temporary search pin", %{conn: conn} do
      user = create_user("search_pin")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 321,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Central Camp",
            "display_name" => "Central Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "central camp"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-321"))

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:321",
        source: "external",
        source_label: "Map",
        kind: "category",
        kind_label: "Camp site",
        title: "Central Camp",
        subtitle: "Central Camp, Stockholm, Sweden",
        lat: 59.3293,
        lng: 18.0686,
        bounds: nil
      })
    end

    test "selecting a different result updates the temporary search pin payload", %{
      conn: conn
    } do
      user = create_user("search_pin_replace")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 111,
            "lat" => "59.3000",
            "lon" => "18.0000",
            "name" => "First Place",
            "display_name" => "First Place, Sweden",
            "class" => "place",
            "type" => "locality"
          },
          %{
            "place_id" => 222,
            "lat" => "59.4000",
            "lon" => "18.1000",
            "name" => "Second Place",
            "display_name" => "Second Place, Sweden",
            "class" => "place",
            "type" => "locality"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "place"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-111"))

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:111",
        source: "external",
        source_label: "Map",
        kind: "place",
        kind_label: "Locality",
        title: "First Place",
        subtitle: "First Place, Sweden",
        lat: 59.3,
        lng: 18.0,
        bounds: nil
      })

      render_click(element(view, "#map-search-result-external-nominatim-222"))

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:222",
        source: "external",
        source_label: "Map",
        kind: "place",
        kind_label: "Locality",
        title: "Second Place",
        subtitle: "Second Place, Sweden",
        lat: 59.4,
        lng: 18.1,
        bounds: nil
      })
    end

    test "selecting a result from a later search replaces the temporary search pin",
         %{conn: conn} do
      user = create_user("search_pin_later_replace")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, 2, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["q"] == "first place" do
          Req.Test.json(conn, [
            %{
              "place_id" => 333,
              "lat" => "59.3000",
              "lon" => "18.0000",
              "name" => "First Later Place",
              "display_name" => "First Later Place, Sweden",
              "class" => "place",
              "type" => "locality"
            }
          ])
        else
          Req.Test.json(conn, [
            %{
              "place_id" => 444,
              "lat" => "59.4000",
              "lon" => "18.1000",
              "name" => "Second Later Place",
              "display_name" => "Second Later Place, Sweden",
              "class" => "place",
              "type" => "locality"
            }
          ])
        end
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "first place"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-333"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:333"})

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "second place"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-444"))

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:444",
        title: "Second Later Place",
        lat: 59.4,
        lng: 18.1
      })
    end

    test "temporary pin clear action removes pin state without clearing search results", %{
      conn: conn
    } do
      user = create_user("search_pin_clear")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 876,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Clear Pin Camp",
            "display_name" => "Clear Pin Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "clear pin camp"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-876"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:876"})

      render_hook(view, "clear_temporary_search_pin", %{})

      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert has_element?(view, "#map-search-results")
      assert has_element?(view, "#map-search-result-external-nominatim-876")

      render_hook(view, "create_poi_from_search_result", %{})

      refute has_element?(view, ~s(#poi-name[value="Clear Pin Camp"]))
      assert list_event_pois(user, event) == []
    end

    test "temporary pin create action opens the POI form with result location", %{conn: conn} do
      user = create_user("search_pin_create")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 321,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Central Camp",
            "display_name" => "Central Camp, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "central camp"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-321"))

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:321",
        source: "external",
        source_label: "Map",
        kind: "category",
        kind_label: "Camp site",
        title: "Central Camp",
        subtitle: "Central Camp, Stockholm, Sweden",
        lat: 59.3293,
        lng: 18.0686,
        bounds: nil
      })

      render_hook(view, "create_poi_from_search_result", %{})

      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert has_element?(view, ~s(#poi-name[value="Central Camp"]))
      assert has_element?(view, "#poi-form", "59.32930, 18.06860")
      assert list_event_pois(user, event) == []
    end

    test "temporary pin create action does not create a POI until the existing form is submitted",
         %{conn: conn} do
      user = create_user("search_pin_create_submit")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 654,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Draft From Search",
            "display_name" => "Draft From Search, Stockholm, Sweden",
            "class" => "tourism",
            "type" => "camp_site"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "draft from search"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-654"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:654"})

      render_hook(view, "create_poi_from_search_result", %{})
      assert_push_event(view, "clear_temporary_search_pin", %{})
      assert list_event_pois(user, event) == []

      render_submit(element(view, "#poi-form"), %{
        "poi" => %{
          "name" => "Draft From Search",
          "description" => "",
          "category" => "viewpoint",
          "color" => "#3B82F6"
        },
        "publish" => "false"
      })

      [poi] = list_event_pois(user, event)
      assert poi.name == "Draft From Search"
      assert poi.visibility == :private
      assert poi.location.coordinates == {18.0686, 59.3293}
    end

    test "temporary pin create action ignores unsupported hook payloads", %{conn: conn} do
      user = create_user("search_pin_create_unsupported")
      event = create_event(user)
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_hook(view, "create_poi_from_search_result", %{
        "title" => "Injected POI",
        "lat" => "12.34",
        "lng" => "56.78"
      })

      refute has_element?(view, ~s(#poi-name[value="Injected POI"]))
      refute has_element?(view, "#poi-form", "12.34000, 56.78000")
      assert list_event_pois(user, event) == []
    end

    test "temporary pin create action uses the selected result instead of hook coordinates",
         %{conn: conn} do
      user = create_user("search_pin_create_selected_only")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        Req.Test.json(conn, [
          %{
            "place_id" => 987,
            "lat" => "59.3293",
            "lon" => "18.0686",
            "name" => "Selected Place",
            "display_name" => "Selected Place, Stockholm, Sweden",
            "class" => "place",
            "type" => "locality"
          }
        ])
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "selected place"}
      })

      render_click(element(view, "#map-search-result-external-nominatim-987"))
      assert_push_event(view, "show_temporary_search_pin", %{id: "external:nominatim:987"})

      render_hook(view, "create_poi_from_search_result", %{
        "title" => "Injected POI",
        "lat" => "12.34",
        "lng" => "56.78"
      })

      assert has_element?(view, ~s(#poi-name[value="Selected Place"]))
      assert has_element?(view, "#poi-form", "59.32930, 18.06860")
      refute has_element?(view, ~s(#poi-name[value="Injected POI"]))
      refute has_element?(view, "#poi-form", "12.34000, 56.78000")
      assert list_event_pois(user, event) == []
    end

    test "temporary pin create action shortens map result names to the first place part", %{
      conn: conn
    } do
      user = create_user("search_pin_create_short")
      event = create_event(user)

      Req.Test.expect(Platser.Map.Search.Geocoder, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/reverse"
        assert conn.query_params["lat"] == "59.3293"
        assert conn.query_params["lon"] == "18.0686"

        Req.Test.json(conn, %{
          "display_name" => "Sergels torg, Stockholm, Sweden",
          "address" => %{
            "square" => "Sergels torg",
            "city" => "Stockholm",
            "country" => "Sweden"
          },
          "class" => "place",
          "type" => "square"
        })
      end)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_submit(element(view, "#map-search-form"), %{
        "search" => %{"query" => "59.3293,18.0686"}
      })

      render_click(
        element(view, "#map-search-result-external-nominatim-coordinate-59-3293-18-0686")
      )

      assert_push_event(view, "show_temporary_search_pin", %{
        id: "external:nominatim:coordinate:59.3293,18.0686",
        source: "external",
        source_label: "Map",
        kind: "coordinate",
        kind_label: "Coordinates",
        title: "Sergels torg, Stockholm, Sweden",
        subtitle: "59.3293, 18.0686",
        lat: 59.3293,
        lng: 18.0686,
        bounds: nil
      })

      render_hook(view, "create_poi_from_search_result", %{})

      assert has_element?(view, ~s(#poi-name[value="Sergels torg"]))
      refute has_element?(view, ~s(#poi-name[value="Sergels torg, Stockholm, Sweden"]))
    end
  end

  test "opens a POI inspection drawer and supports publish", %{conn: conn} do
    user = create_user("poi")
    event = create_event(user)
    poi = create_poi(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} =
      live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

    assert has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#map-item-status-badge")
    assert has_element?(view, "#map-item-focus-btn")
    assert has_element?(view, "#map-item-edit-btn")
    assert has_element?(view, "#map-item-publish-btn")
    assert has_element?(view, "#map-item-delete-btn")

    render_click(element(view, "#map-item-publish-btn"))

    refute has_element?(view, "#map-item-publish-btn")
    assert has_element?(view, "#map-item-drawer")
  end

  test "opens a geofence inspection drawer and supports delete", %{conn: conn} do
    user = create_user("geofence")
    event = create_event(user)
    geofence = create_geofence(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} =
      live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "geofence", id: geofence.id})

    assert has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#map-item-status-badge")
    assert has_element?(view, "#map-item-focus-btn")
    assert has_element?(view, "#map-item-edit-btn")
    assert has_element?(view, "#map-item-fit-boundary-btn")
    refute has_element?(view, "#map-item-publish-btn")
    assert has_element?(view, "#map-item-delete-btn")

    render_click(element(view, "#map-item-delete-btn"))

    refute has_element?(view, "#map-item-drawer")
  end

  test "edit button opens POI edit form pre-filled", %{conn: conn} do
    user = create_user("edit_poi")
    event = create_event(user)
    poi = create_poi(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})
    assert has_element?(view, "#map-item-edit-btn")

    render_click(element(view, "#map-item-edit-btn"))

    refute has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#poi-form")
    assert has_element?(view, "#poi-name")
    assert has_element?(view, "#poi-color")
  end

  test "submitting POI edit form updates the POI", %{conn: conn} do
    user = create_user("edit_poi_submit")
    event = create_event(user)
    poi = create_poi(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})
    render_click(element(view, "#map-item-edit-btn"))

    render_submit(element(view, "#poi-form"), %{
      "poi" => %{
        "name" => "Updated POI Name",
        "description" => "",
        "category" => "viewpoint",
        "color" => "#10B981"
      },
      "publish" => "false"
    })

    updated = PlatserMap.get_poi!(poi.id, actor: user)
    assert updated.name == "Updated POI Name"
    assert updated.color == "#10B981"
    assert updated.visibility == :private
  end

  test "edit button opens geofence edit form pre-filled", %{conn: conn} do
    user = create_user("edit_geofence")
    event = create_event(user)
    geofence = create_geofence(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "geofence", id: geofence.id})
    assert has_element?(view, "#map-item-edit-btn")

    render_click(element(view, "#map-item-edit-btn"))

    refute has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#geofence-form")
    assert has_element?(view, "#geofence-name")
  end

  test "submitting geofence edit form updates the geofence", %{conn: conn} do
    user = create_user("edit_geofence_submit")
    event = create_event(user)
    geofence = create_geofence(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "geofence", id: geofence.id})
    render_click(element(view, "#map-item-edit-btn"))

    render_submit(element(view, "#geofence-form"), %{
      "geofence" => %{
        "name" => "Updated Geofence",
        "purpose" => "boundary",
        "color" => "#3B82F6"
      },
      "publish" => "false"
    })

    updated = PlatserMap.get_geofence!(geofence.id, actor: user)
    assert updated.name == "Updated Geofence"
    assert updated.visibility == :public
  end

  test "edit button shown for published POI (no publish button)", %{conn: conn} do
    user = create_user("published_poi")
    event = create_event(user)
    poi = create_poi(user, event)
    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: published.id})

    assert has_element?(view, "#map-item-focus-btn")
    assert has_element?(view, "#map-item-edit-btn")
    refute has_element?(view, "#map-item-publish-btn")
    assert has_element?(view, "#map-item-delete-btn")
  end

  test "editing a published POI shows the color picker", %{conn: conn} do
    user = create_user("edit_published_poi_form")
    event = create_event(user)
    poi = create_poi(user, event)
    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: published.id})
    render_click(element(view, "#map-item-edit-btn"))

    assert has_element?(view, "#poi-form")
    assert has_element?(view, "#poi-name")
    assert has_element?(view, "#poi-description")
    assert has_element?(view, "#poi-color")
    refute has_element?(view, "#poi-category")
    refute has_element?(view, "#map-item-publish-btn")
  end

  test "saving a published POI name update reopens inspection drawer", %{conn: conn} do
    user = create_user("save_published_poi_name")
    event = create_event(user)
    poi = create_poi(user, event)
    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: published.id})
    render_click(element(view, "#map-item-edit-btn"))

    render_submit(element(view, "#poi-form"), %{
      "poi" => %{"name" => "Renamed Published POI", "description" => ""},
      "publish" => "false"
    })

    assert has_element?(view, "#map-item-drawer")
    updated = PlatserMap.get_poi!(published.id, actor: user)
    assert updated.name == "Renamed Published POI"
    assert updated.visibility == :public
  end

  test "saving a new POI as draft opens inspection drawer for that POI", %{conn: conn} do
    user = create_user("auto_inspect_poi_draft")
    event = create_event(user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "poi_location_picked", %{"lat" => -36.8485, "lng" => 174.7633})

    render_submit(element(view, "#poi-form"), %{
      "poi" => %{
        "name" => "My New Draft POI",
        "description" => "Created via form",
        "category" => "viewpoint"
      },
      "publish" => "false"
    })

    assert has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#map-item-publish-btn")
  end

  test "saving a new POI as published opens inspection drawer for that POI", %{conn: conn} do
    user = create_user("auto_inspect_poi_pub")
    event = create_event(user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "poi_location_picked", %{"lat" => -36.8485, "lng" => 174.7633})

    render_submit(element(view, "#poi-form"), %{
      "poi" => %{
        "name" => "My Published POI",
        "description" => "Published via form",
        "category" => "viewpoint"
      },
      "publish" => "true"
    })

    assert has_element?(view, "#map-item-drawer")
    refute has_element?(view, "#map-item-publish-btn")
  end

  test "saving a new geofence as draft opens inspection drawer for that geofence", %{conn: conn} do
    user = create_user("auto_inspect_fence_draft")
    event = create_event(user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_click(element(view, "#add-geofence-btn"))

    render_hook(view, "vertex_added", %{
      "vertices" => [
        [174.76, -36.85],
        [174.77, -36.85],
        [174.77, -36.84]
      ]
    })

    render_hook(view, "finish_drawing", %{})

    refute has_element?(view, "#geofence-publish-btn")

    render_submit(element(view, "#geofence-form"), %{
      "geofence" => %{
        "name" => "My Draft Geofence",
        "purpose" => "boundary",
        "color" => "#3B82F6"
      }
    })

    assert has_element?(view, "#map-item-drawer")
    refute has_element?(view, "#map-item-publish-btn")
    assert has_element?(view, "#map-item-fit-boundary-btn")
  end

  test "shows the in-event-area chip when the shared position is inside the boundary", %{
    conn: conn
  } do
    user = create_user("boundary_chip")
    event = create_event(user)
    _geofence = create_geofence(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_click(element(view, "#share-location-btn"))

    render_hook(view, "location_update", %{"lat" => -36.845, "lng" => 174.765})

    assert has_element?(view, "#event-boundary-chip")

    render_hook(view, "location_update", %{"lat" => -36.835, "lng" => 174.765})

    refute has_element?(view, "#event-boundary-chip")
  end

  test "photo carousel is shown in inspection drawer when POI has attachments", %{conn: conn} do
    user = create_user("photo_strip_with")
    event = create_event(user)
    poi = create_poi(user, event)
    attachment = create_attachment(user, poi)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

    assert has_element?(view, "#map-item-carousel")
    assert has_element?(view, "#photo-#{attachment.id}")
  end

  describe "photo uploads privacy hardening" do
    property "new POI uploads persist opaque filenames and sanitized bytes" do
      check all(client_name <- upload_client_name_gen(), max_runs: 5) do
        user = create_user("upload_privacy")
        event = create_event(user)
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_hook(view, "poi_location_picked", %{"lat" => -36.8485, "lng" => 174.7633})

        upload =
          file_input(view, "#poi-form", :photos, [
            %{
              name: client_name,
              content: upload_jpeg_with_metadata(),
              size: byte_size(upload_jpeg_with_metadata()),
              type: "image/jpeg"
            }
          ])

        render_upload(upload, client_name)

        render_submit(element(view, "#poi-form"), %{
          "poi" => %{
            "name" => "Upload Privacy POI",
            "description" => "",
            "category" => "viewpoint"
          },
          "publish" => "false"
        })

        [poi] = list_event_pois(user, event)
        {:ok, [attachment]} = Media.list_attachments_for_poi(poi.id, actor: user)

        refute attachment.stored_filename == client_name
        assert Path.basename(attachment.path) == attachment.stored_filename
        assert attachment.filename == "image.jpg"
        assert attachment.content_type == "image/jpeg"

        assert attachment.stored_filename =~
                 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/

        stored_bytes = File.read!(Platser.Media.DiskPath.for_attachment(attachment))
        refute Platser.Media.Upload.contains_sensitive_metadata?(stored_bytes)
      end
    end

    property "unsupported upload names are rejected before persistence" do
      check all(client_name <- rejected_upload_client_name_gen(), max_runs: 3) do
        user = create_user("upload_reject")
        event = create_event(user)
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        render_hook(view, "poi_location_picked", %{"lat" => -36.8485, "lng" => 174.7633})

        upload =
          file_input(view, "#poi-form", :photos, [
            %{name: client_name, content: "not an accepted image", size: 21, type: "text/plain"}
          ])

        render_upload(upload, client_name)

        render_submit(element(view, "#poi-form"), %{
          "poi" => %{
            "name" => "Rejected Upload POI",
            "description" => "",
            "category" => "viewpoint"
          },
          "publish" => "false"
        })

        [poi] = list_event_pois(user, event)
        assert {:ok, []} = Media.list_attachments_for_poi(poi.id, actor: user)
      end
    end
  end

  test "filter chips reset the activity feed stream", %{conn: conn} do
    user = create_user("activity_filters")
    event = create_event(user)
    poi = create_poi(user, event)
    _check_in = insert_activity_entry(user, event, :checked_in, Ecto.UUID.generate())
    _comment = insert_activity_entry(user, event, :comment_added, poi.id)
    _published = insert_activity_entry(user, event, :poi_published, poi.id)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_click(element(view, "#feed-toggle-desktop"))

    assert has_element?(view, "#activity-filter-comments")

    render_click(element(view, "#activity-filter-comments"))

    assert has_element?(view, ~s(#activity-entries [data-action="comment_added"]))
    refute has_element?(view, ~s(#activity-entries [data-action="checked_in"]))
    refute has_element?(view, ~s(#activity-entries [data-action="poi_published"]))

    render_click(element(view, "#activity-filter-updates"))

    assert has_element?(view, ~s(#activity-entries [data-action="checked_in"]))
    assert has_element?(view, ~s(#activity-entries [data-action="poi_published"]))
    refute has_element?(view, ~s(#activity-entries [data-action="comment_added"]))
  end

  test "inspection drawer shows per-item activity and refreshes on comment updates", %{conn: conn} do
    user = create_user("inspection_activity")
    event = create_event(user)
    poi = create_poi(user, event)

    {:ok, _comment_entry} =
      Activity.create_entry(
        %{
          action: :comment_added,
          subject_type: "poi",
          subject_id: poi.id,
          message: "#{user.display_name}: Pinned note",
          event_id: event.id
        },
        actor: user,
        authorize?: false
      )

    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

    assert has_element?(view, "#map-item-activity")
    assert has_element?(view, "#selected-map-object-activity-filter-all")
    assert has_element?(view, "#selected-map-object-activity-filter-comments")
    assert has_element?(view, "#selected-map-object-activity-filter-updates")

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="comment_added"])
           )

    refute has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
           )

    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    _ = render(view)

    assert has_element?(view, "#map-item-drawer")

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
           )

    render_click(element(view, "#selected-map-object-activity-filter-comments"))

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="comment_added"])
           )

    refute has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
           )

    render_click(element(view, "#selected-map-object-activity-filter-updates"))

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
           )

    refute has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="comment_added"])
           )

    refute has_element?(view, "#map-item-publish-btn")
    assert published.visibility == :public
  end

  test "photo carousel is not shown in inspection drawer when POI has no attachments", %{
    conn: conn
  } do
    user = create_user("photo_strip_empty")
    event = create_event(user)
    poi = create_poi(user, event)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

    assert has_element?(view, "#map-item-drawer")
    refute has_element?(view, "#map-item-carousel")
  end

  test "photo carousel survives publish action on inspection drawer", %{conn: conn} do
    user = create_user("photo_strip_publish")
    event = create_event(user)
    poi = create_poi(user, event)
    attachment = create_attachment(user, poi)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

    assert has_element?(view, "#map-item-carousel")

    render_click(element(view, "#map-item-publish-btn"))

    assert has_element?(view, "#map-item-drawer")
    assert has_element?(view, "#map-item-carousel")
    assert has_element?(view, "#photo-#{attachment.id}")
  end

  describe "map navigation (task #44)" do
    property "MapLive always renders a dashboard navigation link" do
      check all(_data <- StreamData.list_of(StreamData.term(), max_length: 5)) do
        user = create_user("nav_prop_user")
        event = create_event(user)
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        # Property: Dashboard link always exists with correct navigate URL
        assert has_element?(view, "a[href*='/dashboard']")
        assert has_element?(view, "a", "Dashboard")
      end
    end

    property "MapLive does not render any link to the join form" do
      check all(_data <- StreamData.list_of(StreamData.term(), max_length: 5)) do
        user = create_user("no_join_form_prop")
        event = create_event(user)
        conn = sign_in_conn(build_conn(), user)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        # Property: No element links to /join/:code
        rendered = render(view)

        # Check that /join/ is not present in any link navigation URLs
        refute String.contains?(rendered, "href=\"/join/")
        refute String.contains?(rendered, "navigate=\"/join/")
      end
    end

    test "users icon navigates to event dashboard, not join form", %{conn: conn} do
      user = create_user("users_icon_nav")
      event = create_event(user)
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # Find the users icon link and verify it points to dashboard
      users_icon_link = element(view, "a[title='View members']")

      # The link should navigate to the dashboard, not the join form
      dashboard_url = ~p"/events/#{event.id}/dashboard"

      rendered_link = render(users_icon_link)
      assert String.contains?(rendered_link, dashboard_url)
      refute String.contains?(rendered_link, ~p"/join/#{event.join_code}")
    end

    test "dashboard link navigates to event dashboard successfully", %{conn: conn} do
      user = create_user("dashboard_link_nav")
      event = create_event(user)
      conn = sign_in_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # Find and verify the dashboard link
      dashboard_link = element(view, "a", "Dashboard")
      assert dashboard_link

      # Render and verify the link contains the correct URL
      rendered_link = render(dashboard_link)
      assert String.contains?(rendered_link, ~p"/events/#{event.id}/dashboard")
    end
  end

  defp upload_client_name_gen do
    StreamData.one_of([
      StreamData.constant("IMG_0001 private gps.jpg"),
      StreamData.constant("passport.scan.jpeg"),
      StreamData.constant("family-location-2026.JPG"),
      StreamData.map(
        StreamData.string(:alphanumeric, min_length: 1, max_length: 18),
        &(&1 <> ".jpg")
      )
    ])
  end

  defp rejected_upload_client_name_gen do
    StreamData.one_of([
      StreamData.constant("private.gif"),
      StreamData.constant("secret.txt"),
      StreamData.map(
        StreamData.string(:alphanumeric, min_length: 1, max_length: 18),
        &(&1 <> ".pdf")
      )
    ])
  end

  defp map_search_provider_payload_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.integer(10_000..99_999),
        StreamData.member_of([
          {:house, "Address"},
          {:restaurant, "Restaurant"},
          {:camp, "Camp site"},
          {:postcode, "Address"}
        ])
      }),
      fn {place_id, {shape, expected_label}} ->
        StreamData.constant(
          {place_id, map_search_provider_payload(place_id, shape), expected_label}
        )
      end
    )
  end

  defp map_search_viewport_bounds_gen do
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

  @spec map_search_payloads(non_neg_integer()) :: [map()]
  defp map_search_payloads(count) do
    1..count//1
    |> Enum.map(fn index ->
      %{
        "place_id" => 9000 + index,
        "lat" => "#{59.0 + index / 1000}",
        "lon" => "#{18.0 + index / 1000}",
        "name" => "Generated Result #{index}",
        "display_name" => "Generated Result #{index}, Sweden",
        "category" => "place",
        "type" => "locality"
      }
    end)
  end

  defp map_search_provider_payload(place_id, :house) do
    %{
      "place_id" => place_id,
      "lat" => "59.334",
      "lon" => "18.063",
      "display_name" => "Generated Road 7, Stockholm, Sweden",
      "category" => "place",
      "type" => "house",
      "addresstype" => "house",
      "address" => %{
        "house_number" => "7",
        "road" => "Generated Road",
        "city" => "Stockholm",
        "country" => "Sweden",
        "country_code" => "se"
      }
    }
  end

  defp map_search_provider_payload(place_id, :restaurant) do
    %{
      "place_id" => place_id,
      "lat" => "59.335",
      "lon" => "18.064",
      "name" => "Generated Restaurant",
      "category" => "amenity",
      "type" => "restaurant"
    }
  end

  defp map_search_provider_payload(place_id, :camp) do
    %{
      "place_id" => place_id,
      "lat" => "59.336",
      "lon" => "18.065",
      "name" => "Generated Camp",
      "class" => "tourism",
      "type" => "camp_site"
    }
  end

  defp map_search_provider_payload(place_id, :postcode) do
    %{
      "place_id" => place_id,
      "lat" => "59.337",
      "lon" => "18.066",
      "display_name" => "123 45, Stockholm, Sweden",
      "type" => "postcode",
      "addresstype" => "postcode",
      "address" => %{
        "postcode" => "123 45",
        "city" => "Stockholm",
        "country" => "Sweden"
      }
    }
  end

  defp upload_jpeg_with_metadata do
    <<0xFF, 0xD8>> <>
      upload_jpeg_segment(0xE1, "Exif\x00\x00private-gps") <>
      upload_jpeg_segment(0xFE, "XMP private comment") <>
      upload_jpeg_segment(0xDB, <<0::64>>) <>
      <<0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 1, 2, 3, 0xFF, 0xD9>>
  end

  defp upload_jpeg_segment(marker, data), do: <<0xFF, marker, byte_size(data) + 2::16>> <> data

  describe "map bounds computation (task #45)" do
    property "computed bounds from any POI set always contains all POI coordinates" do
      check all(
              num_pois <- StreamData.integer(1..10),
              base_lng <- StreamData.float(min: -180.0, max: 160.0),
              base_lat <- StreamData.float(min: -70.0, max: 70.0)
            ) do
        user = create_user("bounds_poi_prop_#{System.unique_integer([:positive])}")
        event = create_event(user)
        conn = sign_in_conn(build_conn(), user)

        # Create POIs with generated coordinates around a base location
        Enum.each(1..num_pois, fn idx ->
          offset_lng = base_lng + idx * 0.1
          offset_lat = base_lat + idx * 0.1

          PlatserMap.create_poi(
            %{
              name: "POI #{idx}",
              description: "Test POI",
              category: :viewpoint,
              location: %Geo.Point{coordinates: {offset_lng, offset_lat}, srid: 4326},
              event_id: event.id
            },
            actor: user
          )
        end)

        {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

        # The map should have initialized without errors
        assert has_element?(view, "#map-canvas")
      end
    end

    test "event with POIs but no bounds uses POI bounding box", %{conn: conn} do
      user = create_user("poi_bounds_user")
      event = create_event(user)

      # Create multiple POIs with known coordinates
      {:ok, _poi1} =
        PlatserMap.create_poi(
          %{
            name: "POI 1",
            description: "Test POI 1",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {10.0, 20.0}, srid: 4326},
            event_id: event.id
          },
          actor: user
        )

      {:ok, _poi2} =
        PlatserMap.create_poi(
          %{
            name: "POI 2",
            description: "Test POI 2",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {30.0, 40.0}, srid: 4326},
            event_id: event.id
          },
          actor: user
        )

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # The map should render successfully
      assert has_element?(view, "#map-canvas")

      # Event should load without errors
      assert has_element?(view, "h1", "Map Live Test")
    end

    test "event with POIs and geofences uses bounding box that encompasses both", %{conn: conn} do
      user = create_user("poi_geofence_bounds_user")
      event = create_event(user)

      # Create a POI
      {:ok, _poi} =
        PlatserMap.create_poi(
          %{
            name: "Test POI",
            description: "Test POI",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
            event_id: event.id
          },
          actor: user
        )

      # Create a geofence
      {:ok, _geofence} =
        PlatserMap.create_geofence(
          %{
            name: "Test Geofence",
            purpose: :meeting_zone,
            color: "#10B981",
            geometry: %Geo.Polygon{
              coordinates: [
                [
                  {10.0, 10.0},
                  {20.0, 10.0},
                  {20.0, 20.0},
                  {10.0, 20.0},
                  {10.0, 10.0}
                ]
              ],
              srid: 4326
            },
            event_id: event.id
          },
          actor: user
        )

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # The map should render successfully
      assert has_element?(view, "#map-canvas")
    end

    test "event with no bounds and no POIs still renders map", %{conn: conn} do
      user = create_user("empty_event_user")
      event = create_event(user)

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # The map should render with default center and zoom
      assert has_element?(view, "#map-canvas")
      assert has_element?(view, "[data-map-center]")
    end

    test "event with explicit bounds ignores POI bounds", %{conn: conn} do
      user = create_user("explicit_bounds_user")
      event = create_event(user)

      # Create POI far away from typical bounds
      {:ok, _poi} =
        PlatserMap.create_poi(
          %{
            name: "Distant POI",
            description: "POI far from center",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
            event_id: event.id
          },
          actor: user
        )

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      # The map should render successfully
      assert has_element?(view, "#map-canvas")
    end

    test "non-admin can submit a comment when public comments are enabled", %{conn: conn} do
      admin = create_user("comment_admin")
      member = create_user("comment_member")
      event = create_event(admin)

      {:ok, _membership} = Platser.Events.join_event(event.join_code, actor: member)

      {:ok, _event} =
        Ash.update(event, %{allow_public_comments: true}, actor: admin, action: :update_settings)

      {:ok, poi} =
        PlatserMap.create_poi(
          %{
            name: "Commentable POI",
            description: "POI for public comment test",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {174.7633, -36.8485}, srid: 4326},
            event_id: event.id
          },
          actor: admin
        )

      {:ok, poi} = PlatserMap.publish_poi(poi, actor: admin)

      conn = sign_in_conn(conn, member)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})
      assert has_element?(view, "#map-item-comment-form")

      render_submit(element(view, "#map-item-comment-form"), %{
        "comment" => %{"body" => "Member note"}
      })

      assert has_element?(view, "#selected-map-object-activity-entries", "Member note")

      {:ok, entries} = Activity.list_entries_for_subject(poi.id, "poi", event.id, actor: member)

      assert Enum.any?(entries, fn entry ->
               entry.action == :comment_added and String.contains?(entry.message, "Member note")
             end)
    end

    test "non-admin can submit a geofence comment when public comments are enabled", %{conn: conn} do
      admin = create_user("comment_admin_geofence")
      member = create_user("comment_member_geofence")
      event = create_event(admin)

      {:ok, _membership} = Platser.Events.join_event(event.join_code, actor: member)

      {:ok, _event} =
        Ash.update(event, %{allow_public_comments: true}, actor: admin, action: :update_settings)

      geofence = create_geofence(admin, event)

      conn = sign_in_conn(conn, member)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_hook(view, "inspect_map_object", %{kind: "geofence", id: geofence.id})
      assert has_element?(view, "#map-item-comment-form")

      render_submit(element(view, "#map-item-comment-form"), %{
        "comment" => %{"body" => "Geofence member note"}
      })

      assert has_element?(view, "#selected-map-object-activity-entries", "Geofence member note")

      {:ok, entries} =
        Activity.list_entries_for_subject(geofence.id, "geofence", event.id, actor: member)

      assert Enum.any?(entries, fn entry ->
               entry.action == :comment_added and
                 entry.subject_type == "geofence" and
                 String.contains?(entry.message, "Geofence member note")
             end)
    end

    test "inspection comments are scoped to selected item subject type and event", %{conn: conn} do
      user = create_user("comment_scope_user")
      event_a = create_event(user)
      event_b = create_event(user)
      poi = create_poi(user, event_a)
      {:ok, poi} = PlatserMap.publish_poi(poi, actor: user)

      {:ok, _entry} =
        Activity.create_entry(
          %{
            action: :comment_added,
            subject_type: "poi",
            subject_id: poi.id,
            message: "#{user.display_name}: Cross-event comment should not render here",
            event_id: event_b.id
          },
          actor: user
        )

      conn = sign_in_conn(conn, user)
      {:ok, view, _html} = live(conn, ~p"/events/#{event_a.id}/map")

      render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

      refute has_element?(
               view,
               "#selected-map-object-activity-entries",
               "Cross-event comment should not render here"
             )
    end

    test "comment form is always visible for admin regardless of public_comments setting", %{
      conn: conn
    } do
      admin = create_user("admin_user2")
      event = create_event(admin)

      # Create a POI
      poi = create_poi(admin, event)

      # Disable public comments using update_settings action
      {:ok, _event} =
        Ash.update(event, %{allow_public_comments: false}, actor: admin, action: :update_settings)

      # Admin views the POI
      conn = sign_in_conn(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

      # Comment form should be visible for admin
      assert has_element?(view, "#map-item-comment-form")
      # Comments disabled message should NOT be shown
      html = render(view)
      refute html =~ "Comments disabled"
    end

    test "non-admin can still read existing comment when public_comments disabled", %{conn: conn} do
      admin = create_user("admin_writer")
      member = create_user("member_reader")
      event = create_event(admin)

      {:ok, _membership} = Platser.Events.join_event(event.join_code, actor: member)

      # Create a POI
      {:ok, draft_poi} =
        PlatserMap.create_poi(
          %{
            name: "Test POI",
            description: "POI for comment test",
            category: :viewpoint,
            location: %Geo.Point{coordinates: {-36.8485, 174.7633}, srid: 4326},
            event_id: event.id
          },
          actor: admin
        )

      {:ok, poi} = PlatserMap.publish_poi(draft_poi, actor: admin)

      # Add a comment to the POI
      {:ok, _comment_entry} =
        Activity.create_entry(
          %{
            action: :comment_added,
            subject_type: "poi",
            subject_id: poi.id,
            message: "#{admin.display_name}: This is an admin comment",
            event_id: event.id
          },
          actor: admin,
          authorize?: false
        )

      # Disable public comments
      {:ok, _event} =
        Ash.update(event, %{allow_public_comments: false}, actor: admin, action: :update_settings)

      # Non-admin views the POI after disabling comments
      conn = sign_in_conn(conn, member)
      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

      render_hook(view, "inspect_map_object", %{kind: "poi", id: poi.id})

      # Comment should still be visible in read-only mode
      html = render(view)
      assert html =~ "This is an admin comment"
      assert html =~ "Comments are disabled for members right now"
      refute has_element?(view, "#map-item-comment-form")
    end
  end
end
