defmodule Platser.PoiMetadataEditPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Map, as: PlatserMap

  @moduledoc """
  StreamData property tests for the update_metadata action on published POIs
  and geofences. Verifies that name/description updates are accepted and
  persisted regardless of visibility, and that structural fields (category,
  location, geometry, purpose) cannot be changed via update_metadata.
  """

  # ── Generators ──────────────────────────────────────────────────────────────

  defp valid_name_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 80)
    |> StreamData.filter(&(String.trim(&1) != ""))
  end

  defp valid_description_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.string(:printable, min_length: 0, max_length: 200)
    ])
  end

  defp valid_hex_color_gen do
    hex_char = StreamData.member_of(~c"0123456789abcdef")

    StreamData.list_of(hex_char, length: 6)
    |> StreamData.map(fn chars -> "#" <> List.to_string(chars) end)
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "poi_meta_#{n}@example.com",
          display_name: "Meta User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event(user) do
    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  defp create_published_poi(user, event) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Original Name",
          description: "Original description",
          category: :viewpoint,
          location: %Geo.Point{coordinates: {10.0, 20.0}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    {:ok, published} = PlatserMap.publish_poi(poi, actor: user)
    published
  end

  defp create_published_geofence(user, event) do
    polygon = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]],
      srid: 4326
    }

    {:ok, geofence} =
      PlatserMap.create_geofence(
        %{
          name: "Original Geofence",
          purpose: :meeting_zone,
          color: "#3B82F6",
          geometry: polygon,
          event_id: event.id
        },
        actor: user
      )

    {:ok, published} = PlatserMap.publish_geofence(geofence, actor: user)
    published
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "POI update_metadata on published POI" do
    property "any valid name is accepted and persisted" do
      check all(new_name <- valid_name_gen(), max_runs: 30) do
        user = create_user()
        event = create_event(user)
        poi = create_published_poi(user, event)

        result = PlatserMap.update_poi_metadata(poi, %{name: new_name}, actor: user)

        assert {:ok, updated} = result
        assert updated.name == new_name
        assert updated.visibility == :public
      end
    end

    property "name plus optional description are both persisted" do
      check all(
              new_name <- valid_name_gen(),
              new_desc <- valid_description_gen(),
              max_runs: 20
            ) do
        user = create_user()
        event = create_event(user)
        poi = create_published_poi(user, event)

        attrs = %{name: new_name, description: new_desc}
        result = PlatserMap.update_poi_metadata(poi, attrs, actor: user)

        assert {:ok, updated} = result
        assert updated.name == new_name
        assert updated.description == if(new_desc == "", do: nil, else: new_desc)
        assert updated.visibility == :public
      end
    end

    property "category and location are not accepted by update_metadata" do
      check all(new_name <- valid_name_gen(), max_runs: 10) do
        user = create_user()
        event = create_event(user)
        poi = create_published_poi(user, event)

        result =
          PlatserMap.update_poi_metadata(
            poi,
            %{
              name: new_name,
              category: :camp,
              location: %Geo.Point{coordinates: {99.0, 99.0}, srid: 4326}
            },
            actor: user
          )

        assert {:error, %Ash.Error.Invalid{}} = result
      end
    end
  end

  describe "Geofence update_metadata on published geofence" do
    property "any valid name and color are accepted and persisted" do
      check all(
              new_name <- valid_name_gen(),
              new_color <- valid_hex_color_gen(),
              max_runs: 20
            ) do
        user = create_user()
        event = create_event(user)
        geofence = create_published_geofence(user, event)

        result =
          PlatserMap.update_geofence_metadata(geofence, %{name: new_name, color: new_color},
            actor: user
          )

        assert {:ok, updated} = result
        assert updated.name == new_name
        assert updated.color == new_color
        assert updated.visibility == :public
      end
    end

    property "purpose is not accepted by update_metadata" do
      check all(new_name <- valid_name_gen(), max_runs: 10) do
        user = create_user()
        event = create_event(user)
        geofence = create_published_geofence(user, event)

        result =
          PlatserMap.update_geofence_metadata(
            geofence,
            %{name: new_name, purpose: :restricted},
            actor: user
          )

        assert {:error, %Ash.Error.Invalid{}} = result
      end
    end
  end
end
