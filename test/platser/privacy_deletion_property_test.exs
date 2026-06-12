defmodule Platser.PrivacyDeletionPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap
  alias Platser.Privacy
  alias Platser.Privacy.ExportBuilder
  alias Platser.Repo

  property "account deletion anonymizes identifiers and preserves user-linked history" do
    check all(
            poi_count <- StreamData.integer(0..2),
            geofence_count <- StreamData.integer(0..2),
            check_in_count <- StreamData.integer(1..2),
            max_runs: 5
          ) do
      user = create_user("subject")
      old_email = to_string(user.email)
      _signed_in_user = sign_in_user(user)
      event = create_event(user, "Deletion Event")

      pois =
        for index <- 1..poi_count//1 do
          poi = create_poi(user, event, index)
          {:ok, poi} = PlatserMap.update_poi_comment(poi, %{comment: "PII #{index}"}, actor: user)
          poi
        end

      geofences =
        for index <- 1..geofence_count//1 do
          geofence = create_geofence(user, event, index)

          {:ok, geofence} =
            PlatserMap.update_geofence_comment(geofence, %{comment: "Zone PII #{index}"},
              actor: user
            )

          geofence
        end

      check_ins =
        for index <- 1..check_in_count//1 do
          create_check_in(user, event, index)
        end

      other_user = create_user("other")
      other_event = create_event(other_user, "Other Event")
      other_check_in = create_check_in(other_user, other_event, 99)

      assert token_count(user.id) > 0
      assert {:ok, result} = Privacy.delete_account(user)

      anonymized = Ash.get!(User, user.id, authorize?: false)

      assert anonymized.email != old_email
      assert to_string(anonymized.email) == "deleted_#{user.id}@platser.deleted"
      assert anonymized.display_name == "Deleted user"
      assert is_nil(anonymized.hashed_password)
      assert anonymized.is_guest == false
      assert anonymized.superuser == false
      assert %DateTime{} = anonymized.deleted_at
      assert token_count(user.id) == 0

      assert result.outcome_counts["users_anonymized"] == 1
      assert result.outcome_counts["tokens_revoked"] > 0
      assert result.outcome_counts["activity_entries_anonymized"] >= length(check_ins)
      assert result.outcome_counts["poi_comments_cleared"] == length(pois)
      assert result.outcome_counts["geofence_comments_cleared"] == length(geofences)

      assert Repo.aggregate(
               from(m in "memberships", where: m.user_id == type(^user.id, :binary_id)),
               :count
             ) ==
               1

      assert Enum.all?(entries_for(user.id), fn entry ->
               entry.message == "[deleted account]" and is_nil(entry.lat) and is_nil(entry.lng)
             end)

      assert Enum.all?(pois_for(user.id), &is_nil(&1.comment))
      assert Enum.all?(geofences_for(user.id), &is_nil(&1.comment))

      assert [%{message: "Check-in 99", lat: lat, lng: lng}] = entries_for(other_user.id)
      assert is_float(lat)
      assert is_float(lng)

      assert {:ok, payload} = ExportBuilder.build_payload(user.id)
      assert payload.data.account.email == "deleted_#{user.id}@platser.deleted"
      refute payload.data.account.email == old_email

      assert {:error, :already_deleted} = Privacy.delete_account(anonymized)

      assert Ash.get!(Platser.Privacy.Deletion, result.deletion.id, authorize?: false).user_id ==
               user.id

      assert other_check_in.actor_id == other_user.id
    end
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "privacy_delete_#{tag}_#{n}@example.com",
          display_name: "Privacy Delete #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec sign_in_user(User.t()) :: User.t()
  defp sign_in_user(user) do
    {:ok, signed_in_user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => user.email, "password" => "password123"}
      )

    signed_in_user
  end

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(user, name) do
    now = DateTime.utc_now(:second)

    {:ok, event} =
      Ash.create(
        Event,
        %{
          name: name,
          description: "Deletion test event",
          starts_at: now,
          ends_at: DateTime.add(now, 3600)
        },
        actor: user
      )

    event
  end

  @spec create_poi(User.t(), Event.t(), integer()) :: Platser.Map.Poi.t()
  defp create_poi(user, event, index) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Deletion POI #{index}",
          description: "POI #{index}",
          category: :viewpoint,
          color: "#3B82F6",
          location: %Geo.Point{coordinates: {18.0 + index / 1000, 59.0}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
  end

  @spec create_geofence(User.t(), Event.t(), integer()) :: Platser.Map.Geofence.t()
  defp create_geofence(user, event, index) do
    offset = index / 1000

    {:ok, geofence} =
      PlatserMap.create_geofence(
        %{
          name: "Deletion Geofence #{index}",
          description: "Geofence #{index}",
          purpose: :meeting_zone,
          color: "#10B981",
          geometry: %Geo.Polygon{
            coordinates: [
              [
                {18.0 + offset, 59.0},
                {18.01 + offset, 59.0},
                {18.01 + offset, 59.01},
                {18.0 + offset, 59.01},
                {18.0 + offset, 59.0}
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

  @spec create_check_in(User.t(), Event.t(), integer()) :: Platser.Activity.Entry.t()
  defp create_check_in(user, event, index) do
    {:ok, entry} =
      Activity.create_check_in(
        %{
          event_id: event.id,
          lat: 59.0 + index / 1000,
          lng: 18.0 + index / 1000,
          message: "Check-in #{index}"
        },
        actor: user
      )

    entry
  end

  @spec token_count(Ecto.UUID.t() | String.t()) :: non_neg_integer()
  defp token_count(user_id) do
    subject_suffix = user_id

    Repo.aggregate(
      from(t in "tokens", where: like(t.subject, ^"%#{subject_suffix}")),
      :count
    )
  end

  @spec entries_for(Ecto.UUID.t() | String.t()) :: [map()]
  defp entries_for(user_id) do
    Repo.all(
      from e in "entries",
        where: e.actor_id == type(^user_id, :binary_id),
        order_by: e.inserted_at,
        select: %{message: e.message, lat: e.lat, lng: e.lng}
    )
  end

  @spec pois_for(Ecto.UUID.t() | String.t()) :: [map()]
  defp pois_for(user_id) do
    Repo.all(
      from p in "pois",
        where: p.creator_id == type(^user_id, :binary_id),
        select: %{comment: p.comment}
    )
  end

  @spec geofences_for(Ecto.UUID.t() | String.t()) :: [map()]
  defp geofences_for(user_id) do
    Repo.all(
      from g in "geofences",
        where: g.creator_id == type(^user_id, :binary_id),
        select: %{comment: g.comment}
    )
  end
end
