defmodule Platser.GpsSimulatorPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User
  alias Platser.Dev.GpsSimulator
  alias Platser.EventPresence

  @max_ticks 20

  defp create_user(email, display_name) do
    User
    |> Ash.Changeset.for_create(:create_simulated, %{email: email, display_name: display_name})
    |> Ash.create!(authorize?: false)
  end

  defp create_event(owner, name) do
    now = DateTime.utc_now()

    Platser.Events.Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        description: "Simulator test event",
        starts_at: now,
        ends_at: DateTime.add(now, 3600, :second)
      },
      actor: owner
    )
    |> Ash.create!(authorize?: false)
  end

  defp user_state(state, user_id) do
    Enum.find(state.users, &(&1.user.id == user_id))
  end

  defp position_for(state, user_id) do
    tracked = user_state(state, user_id)
    {tracked.lat, tracked.lng}
  end

  defp distance({lat1, lng1}, {lat2, lng2}) do
    :math.sqrt(:math.pow(lat2 - lat1, 2) + :math.pow(lng2 - lng1, 2))
  end

  defp within_bounds?(lat, lng) do
    lat >= -90.0 and lat <= 90.0 and lng >= -180.0 and lng <= 180.0
  end

  property "stationary users never move" do
    owner = create_user("owner-#{System.unique_integer([:positive])}@dev.local", "Owner")
    event = create_event(owner, "Stationary #{System.unique_integer([:positive])}")
    simulator = start_supervisor_for(event.id)

    check all(
            n <- StreamData.integer(1..@max_ticks),
            lat <- StreamData.float(min: -70.0, max: 70.0),
            lng <- StreamData.float(min: -170.0, max: 170.0)
          ) do
      user =
        create_user("stationary-#{System.unique_integer([:positive])}@dev.local", "Stationary")

      :ok = GpsSimulator.add_user(simulator, user, :stationary, lat: lat, lng: lng)

      initial = {lat, lng}

      positions =
        Enum.map(1..n, fn _ ->
          :ok = GpsSimulator.tick_now(simulator)
          position_for(GpsSimulator.get_state(simulator), user.id)
        end)

      assert Enum.all?(positions, &(&1 == initial))
      :ok = GpsSimulator.remove_user(simulator, user.id)
    end
  end

  property "linear users keep moving toward the target" do
    owner = create_user("linear-owner-#{System.unique_integer([:positive])}@dev.local", "Owner")
    event = create_event(owner, "Linear #{System.unique_integer([:positive])}")
    simulator = start_supervisor_for(event.id)

    check all(
            n <- StreamData.integer(1..@max_ticks),
            start_lat <- StreamData.float(min: -60.0, max: 60.0),
            start_lng <- StreamData.float(min: -150.0, max: 150.0),
            delta_lat <- StreamData.float(min: 0.01, max: 2.0),
            delta_lng <- StreamData.float(min: 0.01, max: 2.0)
          ) do
      user = create_user("linear-#{System.unique_integer([:positive])}@dev.local", "Linear")

      :ok =
        GpsSimulator.add_user(simulator, user, :linear,
          start_lat: start_lat,
          start_lng: start_lng,
          end_lat: start_lat + delta_lat,
          end_lng: start_lng + delta_lng,
          total_steps: @max_ticks
        )

      target = {start_lat + delta_lat, start_lng + delta_lng}

      distances =
        Enum.map(1..n, fn _ ->
          :ok = GpsSimulator.tick_now(simulator)

          position_for(GpsSimulator.get_state(simulator), user.id)
          |> distance(target)
        end)

      assert Enum.chunk_every(distances, 2, 1, :discard)
             |> Enum.all?(fn [prev, next] -> next <= prev + 1.0e-9 end)

      :ok = GpsSimulator.remove_user(simulator, user.id)
    end
  end

  property "random walk users stay within WGS-84 bounds" do
    owner = create_user("walk-owner-#{System.unique_integer([:positive])}@dev.local", "Owner")
    event = create_event(owner, "Walk #{System.unique_integer([:positive])}")
    simulator = start_supervisor_for(event.id)

    check all(
            n <- StreamData.integer(1..@max_ticks),
            lat <- StreamData.float(min: -70.0, max: 70.0),
            lng <- StreamData.float(min: -170.0, max: 170.0)
          ) do
      user = create_user("walk-#{System.unique_integer([:positive])}@dev.local", "Walker")

      :ok =
        GpsSimulator.add_user(simulator, user, :random_walk, lat: lat, lng: lng, step_size: 0.5)

      positions =
        Enum.map(1..n, fn _ ->
          :ok = GpsSimulator.tick_now(simulator)
          position_for(GpsSimulator.get_state(simulator), user.id)
        end)

      assert Enum.all?(positions, fn {lat, lng} -> within_bounds?(lat, lng) end)
      :ok = GpsSimulator.remove_user(simulator, user.id)
    end
  end

  property "presence mirrors the simulator's last tick" do
    owner = create_user("presence-owner-#{System.unique_integer([:positive])}@dev.local", "Owner")
    event = create_event(owner, "Presence #{System.unique_integer([:positive])}")
    simulator = start_supervisor_for(event.id)

    check all(
            n <- StreamData.integer(1..@max_ticks),
            lat <- StreamData.float(min: -50.0, max: 50.0),
            lng <- StreamData.float(min: -120.0, max: 120.0)
          ) do
      user = create_user("presence-#{System.unique_integer([:positive])}@dev.local", "Presence")

      :ok =
        GpsSimulator.add_user(simulator, user, :linear,
          start_lat: lat,
          start_lng: lng,
          end_lat: lat + 0.02,
          end_lng: lng + 0.02,
          total_steps: @max_ticks
        )

      Enum.each(1..n, fn _ -> :ok = GpsSimulator.tick_now(simulator) end)

      state = GpsSimulator.get_state(simulator)
      {expected_lat, expected_lng} = position_for(state, user.id)
      presence = EventPresence.list_locations(event.id)[user.id]

      assert presence.lat == expected_lat
      assert presence.lng == expected_lng
      :ok = GpsSimulator.remove_user(simulator, user.id)
    end
  end

  defp start_supervisor_for(event_id) do
    start_supervised!({GpsSimulator, [event_id: event_id, tick_ms: 60_000]})
  end
end
