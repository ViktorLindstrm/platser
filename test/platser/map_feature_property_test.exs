defmodule Platser.MapFeaturePropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Map, as: PlatserMap

  @moduledoc """
  StreamData property tests asserting that POI and geofence resources
  always persist a non-nil name — the contract the hover tooltip relies on.
  """

  # ── Generators ──────────────────────────────────────────────────────────────

  defp valid_name_gen do
    StreamData.string(:printable, min_length: 1, max_length: 80)
    |> StreamData.filter(&(String.trim(&1) != ""))
  end

  defp valid_point_gen do
    StreamData.map(
      StreamData.tuple({
        StreamData.float(min: -170.0, max: 170.0),
        StreamData.float(min: -80.0, max: 80.0)
      }),
      fn {lng, lat} -> %Geo.Point{coordinates: {lng, lat}, srid: 4326} end
    )
  end

  defp valid_polygon_gen do
    StreamData.map(
      StreamData.tuple({
        StreamData.float(min: -170.0, max: 170.0),
        StreamData.float(min: -80.0, max: 80.0),
        StreamData.float(min: 0.01, max: 5.0)
      }),
      fn {lng, lat, size} ->
        ring = [{lng, lat}, {lng + size, lat}, {lng + size, lat + size}, {lng, lat}]
        %Geo.Polygon{coordinates: [ring], srid: 4326}
      end
    )
  end

  defp category_gen do
    StreamData.member_of([:viewpoint, :camp, :hazard, :meeting_point, :food, :other])
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "map_feature_#{n}@example.com",
          display_name: "Feature User #{n}",
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
          name: "Feature Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "POI name contract (hover tooltip invariant)" do
    property "POI created with a valid name always persists that name" do
      check all(
              name <- valid_name_gen(),
              point <- valid_point_gen(),
              category <- category_gen(),
              max_runs: 15
            ) do
        user = create_user()
        event = create_event(user)

        {:ok, poi} =
          PlatserMap.create_poi(
            %{
              name: name,
              category: category,
              location: point,
              event_id: event.id
            },
            actor: user
          )

        assert poi.name == name
        assert is_binary(poi.name)
        assert poi.name != ""
      end
    end
  end

  describe "Geofence name contract (hover tooltip invariant)" do
    property "geofence created with a valid name always persists that name" do
      check all(
              name <- valid_name_gen(),
              polygon <- valid_polygon_gen(),
              max_runs: 15
            ) do
        user = create_user()
        event = create_event(user)

        {:ok, geofence} =
          PlatserMap.create_geofence(
            %{
              name: name,
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        assert geofence.name == name
        assert is_binary(geofence.name)
        assert geofence.name != ""
      end
    end
  end
end
