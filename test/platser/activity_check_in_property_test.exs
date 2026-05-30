defmodule Platser.ActivityCheckInPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Activity

  @moduledoc """
  StreamData property tests for check-in persistence and validation.
  """

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "check_in_test_#{n}@example.com",
          display_name: "Check In User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event_with_member do
    user = create_user()

    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Check In Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    {user, event}
  end

  defp valid_lat_gen do
    StreamData.float(min: -90.0, max: 90.0)
  end

  defp valid_lng_gen do
    StreamData.float(min: -180.0, max: 180.0)
  end

  defp invalid_lat_gen do
    StreamData.one_of([
      StreamData.float(min: -1_000.0, max: -90.0001),
      StreamData.float(min: 90.0001, max: 1_000.0)
    ])
  end

  defp invalid_lng_gen do
    StreamData.one_of([
      StreamData.float(min: -1_000.0, max: -180.0001),
      StreamData.float(min: 180.0001, max: 1_000.0)
    ])
  end

  describe "check-in validation" do
    property "valid WGS-84 coordinates always create a check-in" do
      check all(
              lat <- valid_lat_gen(),
              lng <- valid_lng_gen(),
              max_runs: 40
            ) do
        {user, event} = create_event_with_member()

        assert {:ok, entry} =
                 Activity.create_check_in(
                   %{
                     event_id: event.id,
                     lat: lat,
                     lng: lng,
                     message: "Checked in"
                   },
                   actor: user
                 )

        assert entry.action == :checked_in
        assert entry.subject_type == "user"
        assert entry.subject_id == user.id
        assert entry.lat == lat
        assert entry.lng == lng
      end
    end

    property "latitudes outside WGS-84 bounds are rejected" do
      check all(
              lat <- invalid_lat_gen(),
              lng <- valid_lng_gen(),
              max_runs: 40
            ) do
        {user, event} = create_event_with_member()

        assert {:error, _} =
                 Activity.create_check_in(
                   %{
                     event_id: event.id,
                     lat: lat,
                     lng: lng,
                     message: "Checked in"
                   },
                   actor: user
                 )
      end
    end

    property "longitudes outside WGS-84 bounds are rejected" do
      check all(
              lat <- valid_lat_gen(),
              lng <- invalid_lng_gen(),
              max_runs: 40
            ) do
        {user, event} = create_event_with_member()

        assert {:error, _} =
                 Activity.create_check_in(
                   %{
                     event_id: event.id,
                     lat: lat,
                     lng: lng,
                     message: "Checked in"
                   },
                   actor: user
                 )
      end
    end
  end

  describe "check-in persistence" do
    property "multiple check-ins by the same user always create distinct entries" do
      check all(
              count <- StreamData.integer(2..6),
              lat <- valid_lat_gen(),
              lng <- valid_lng_gen(),
              max_runs: 20
            ) do
        {user, event} = create_event_with_member()

        entries =
          Enum.map(1..count, fn index ->
            assert {:ok, entry} =
                     Activity.create_check_in(
                       %{
                         event_id: event.id,
                         lat: lat,
                         lng: lng,
                         message: "Check in #{index}"
                       },
                       actor: user
                     )

            entry
          end)

        ids = Enum.map(entries, & &1.id)

        assert length(Enum.uniq(ids)) == count

        assert {:ok, fetched} = Activity.list_check_ins_for_event(event.id, actor: user)
        assert length(fetched) == count
      end
    end
  end
end
