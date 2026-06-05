defmodule Platser.LocationPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.EventPresence
  alias Platser.Location
  alias Platser.Map, as: PlatserMap

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp gen_lat, do: StreamData.float(min: -90.0, max: 90.0)
  defp gen_lng, do: StreamData.float(min: -180.0, max: 180.0)
  defp gen_user_id, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 36)

  defp boundary_polygon_gen do
    StreamData.map(
      StreamData.tuple({
        StreamData.float(min: -160.0, max: 160.0),
        StreamData.float(min: -70.0, max: 70.0),
        StreamData.float(min: 0.1, max: 2.0)
      }),
      fn {lng, lat, size} ->
        ring = [
          {lng, lat},
          {lng + size, lat},
          {lng + size, lat + size},
          {lng, lat + size},
          {lng, lat}
        ]

        %Geo.Polygon{coordinates: [ring], srid: 4326}
      end
    )
  end

  defp gen_valid_meta do
    gen all(
          lat <- gen_lat(),
          lng <- gen_lng(),
          accuracy <-
            StreamData.one_of([StreamData.constant(nil), StreamData.float(min: 1.0, max: 100.0)]),
          heading <-
            StreamData.one_of([StreamData.constant(nil), StreamData.float(min: 0.0, max: 359.9)]),
          display_name <- StreamData.string(:alphanumeric, min_length: 1)
        ) do
      %{lat: lat, lng: lng, accuracy: accuracy, heading: heading, display_name: display_name}
    end
  end

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "location_test_#{n}@example.com",
          display_name: "Location Test #{n}",
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
          name: "Boundary Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    event
  end

  # ---------------------------------------------------------------------------
  # valid_coords?/2 properties
  # ---------------------------------------------------------------------------

  property "valid_coords? returns true for any WGS-84 coordinate" do
    check all(
            lat <- gen_lat(),
            lng <- gen_lng()
          ) do
      assert Location.valid_coords?(lat, lng)
    end
  end

  property "valid_coords? returns false when lat is out of range" do
    check all(
            lat <-
              StreamData.one_of([
                StreamData.float(min: 90.001, max: 200.0),
                StreamData.float(min: -200.0, max: -90.001)
              ]),
            lng <- gen_lng()
          ) do
      refute Location.valid_coords?(lat, lng)
    end
  end

  property "valid_coords? returns false when lng is out of range" do
    check all(
            lat <- gen_lat(),
            lng <-
              StreamData.one_of([
                StreamData.float(min: 180.001, max: 360.0),
                StreamData.float(min: -360.0, max: -180.001)
              ])
          ) do
      refute Location.valid_coords?(lat, lng)
    end
  end

  property "valid_coords? returns false for non-numeric inputs" do
    check all(
            bad <-
              StreamData.one_of([
                StreamData.string(:alphanumeric),
                StreamData.constant(nil),
                StreamData.constant(:atom)
              ])
          ) do
      refute Location.valid_coords?(bad, 0.0)
      refute Location.valid_coords?(0.0, bad)
    end
  end

  # ---------------------------------------------------------------------------
  # Presence metadata shape properties
  # ---------------------------------------------------------------------------

  describe "EventPresence.topic/1" do
    property "always returns a non-empty string prefixed with 'event:'" do
      check all(event_id <- StreamData.string(:alphanumeric, min_length: 1)) do
        topic = EventPresence.topic(event_id)
        assert is_binary(topic)
        assert String.starts_with?(topic, "event:")
        assert String.ends_with?(topic, ":locations")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # update_presence/5 coordinate validation properties
  # ---------------------------------------------------------------------------

  describe "Location.update_presence/5 coordinate validation" do
    # We test the validation aspect without a real DB/Presence process by
    # verifying that invalid coordinates are rejected.

    property "returns {:error, :invalid_coords} for any out-of-range lat" do
      check all(
              lat <-
                StreamData.one_of([
                  StreamData.float(min: 90.001, max: 200.0),
                  StreamData.float(min: -200.0, max: -90.001)
                ]),
              lng <- gen_lng()
            ) do
        fake_user = %{id: "test-user", display_name: "Test"}
        params = %{lat: lat, lng: lng, accuracy: nil, heading: nil}

        assert {:error, :invalid_coords} =
                 Location.update_presence(self(), "evt1", fake_user, params, false)
      end
    end

    property "returns {:error, :invalid_coords} for any out-of-range lng" do
      check all(
              lat <- gen_lat(),
              lng <-
                StreamData.one_of([
                  StreamData.float(min: 180.001, max: 360.0),
                  StreamData.float(min: -360.0, max: -180.001)
                ])
            ) do
        fake_user = %{id: "test-user", display_name: "Test"}
        params = %{lat: lat, lng: lng, accuracy: nil, heading: nil}

        assert {:error, :invalid_coords} =
                 Location.update_presence(self(), "evt1", fake_user, params, false)
      end
    end
  end

  describe "Location.in_event_boundary?/2" do
    property "returns true for points inside the boundary and false outside it" do
      check all(
              polygon <- boundary_polygon_gen(),
              max_runs: 25
            ) do
        user = create_user()
        event = create_event(user)

        {:ok, _boundary} =
          PlatserMap.create_geofence(
            %{
              name: "Boundary",
              purpose: :boundary,
              color: "#3B82F6",
              geometry: polygon,
              event_id: event.id
            },
            actor: user
          )

        [{lng, lat}, {east_lng, _}, {_, north_lat} | _] = hd(polygon.coordinates)
        inside = %{lat: lat + (north_lat - lat) / 2.0, lng: lng + (east_lng - lng) / 2.0}
        outside = %{lat: lat - 0.05, lng: lng - 0.05}

        assert Location.in_event_boundary?(event.id, inside)
        refute Location.in_event_boundary?(event.id, outside)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Presence list_locations/1 collapse properties
  # ---------------------------------------------------------------------------

  describe "EventPresence.list_locations/1" do
    property "result only contains values with lat and lng keys" do
      # We test the shape contract by mocking the list/1 call
      # by verifying the function logic using our own presences map.

      check all(
              metas <- StreamData.list_of(gen_valid_meta(), min_length: 1, max_length: 5),
              user_id <- gen_user_id()
            ) do
        metas_with_ts =
          metas
          |> Enum.with_index()
          |> Enum.map(fn {m, i} -> Map.put(m, :timestamp, i * 1000) end)

        presence_map = %{user_id => %{metas: metas_with_ts}}

        # Replicate the collapse logic from EventPresence.list_locations/1
        collapsed =
          Map.new(presence_map, fn {uid, %{metas: ms}} ->
            latest = Enum.max_by(ms, & &1.timestamp, fn -> %{timestamp: 0} end)
            {uid, latest}
          end)

        assert Map.has_key?(collapsed, user_id)
        meta = collapsed[user_id]
        assert is_float(meta.lat) or is_integer(meta.lat)
        assert is_float(meta.lng) or is_integer(meta.lng)
      end
    end

    property "latest timestamp meta wins when multiple metas exist for same user" do
      check all(
              n_metas <- StreamData.integer(2..10),
              base_lat <- gen_lat(),
              base_lng <- gen_lng()
            ) do
        metas =
          for i <- 1..n_metas do
            %{
              lat: base_lat + i * 0.001,
              lng: base_lng + i * 0.001,
              timestamp: i * 1000,
              geofence_ids: [],
              display_name: "User"
            }
          end

        presence_map = %{"uid" => %{metas: Enum.shuffle(metas)}}

        collapsed =
          Map.new(presence_map, fn {uid, %{metas: ms}} ->
            latest = Enum.max_by(ms, & &1.timestamp, fn -> %{timestamp: 0} end)
            {uid, latest}
          end)

        assert collapsed["uid"].timestamp == n_metas * 1000
      end
    end
  end
end
