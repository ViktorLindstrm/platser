defmodule PlatserWeb.MapLiveTest do
  use PlatserWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
    assert has_element?(view, "#map-item-publish-btn")
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
      "poi" => %{"name" => "Updated POI Name", "description" => "", "category" => "viewpoint"},
      "publish" => "false"
    })

    updated = PlatserMap.get_poi!(poi.id, actor: user)
    assert updated.name == "Updated POI Name"
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
    assert updated.visibility == :private
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

  test "editing a published POI shows only name/description fields", %{conn: conn} do
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

    render_submit(element(view, "#geofence-form"), %{
      "geofence" => %{
        "name" => "My Draft Geofence",
        "purpose" => "boundary",
        "color" => "#3B82F6"
      },
      "publish" => "false"
    })

    assert has_element?(view, "#map-item-drawer")
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
end
