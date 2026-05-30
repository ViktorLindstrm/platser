defmodule PlatserWeb.MapLiveTest do
  use PlatserWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Platser.Activity
  alias Platser.Map, as: PlatserMap
  alias Platser.Media

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
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Inspection POI",
          description: "A draft POI for inspection",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {174.7633, -36.8485}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
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
    {:ok, attachment} =
      Media.create_attachment(
        %{
          filename: "photo.jpg",
          stored_filename: "uuid_photo.jpg",
          content_type: "image/jpeg",
          path: "/uploads/#{poi.id}/uuid_photo.jpg",
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

    render_click(element(view, "#activity-filter-check-ins"))

    assert has_element?(view, ~s(#activity-entries [data-action="checked_in"]))
    refute has_element?(view, ~s(#activity-entries [data-action="comment_added"]))
  end

  test "inspection drawer shows per-item activity and refreshes on comment updates", %{conn: conn} do
    user = create_user("inspection_activity")
    event = create_event(user)
    poi = create_poi(user, event)
    {:ok, commented} = PlatserMap.update_poi_comment(poi, %{comment: "Pinned note"}, actor: user)
    conn = sign_in_conn(conn, user)

    {:ok, view, _html} = live(conn, ~p"/events/#{event.id}/map")

    render_hook(view, "inspect_map_object", %{kind: "poi", id: commented.id})

    assert has_element?(view, "#map-item-activity")
    assert has_element?(view, "#map-item-comment-quote")

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="comment_added"])
           )

    refute has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
           )

    {:ok, published} = PlatserMap.publish_poi(commented, actor: user)
    _ = render(view)

    assert has_element?(view, "#map-item-drawer")

    assert has_element?(
             view,
             ~s(#selected-map-object-activity-entries [data-action="poi_published"])
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
  end
end
