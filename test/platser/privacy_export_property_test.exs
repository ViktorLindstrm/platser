defmodule Platser.PrivacyExportPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap
  alias Platser.Media
  alias Platser.Privacy.ExportBuilder

  property "DSAR payload includes linked user records and excludes other users" do
    check all(
            poi_count <- StreamData.integer(0..2),
            geofence_count <- StreamData.integer(0..2),
            check_in_count <- StreamData.integer(0..2),
            max_runs: 5
          ) do
      user = create_user("subject")
      event = create_event(user, "Subject Event")

      pois =
        for index <- 1..poi_count//1 do
          poi = create_poi(user, event, index)

          {:ok, poi} =
            PlatserMap.update_poi_comment(poi, %{comment: "Subject comment #{index}"},
              actor: user
            )

          create_attachment(user, poi)
          poi
        end

      geofences =
        for index <- 1..geofence_count//1 do
          geofence = create_geofence(user, event, index)

          {:ok, geofence} =
            PlatserMap.update_geofence_comment(
              geofence,
              %{comment: "Subject zone comment #{index}"},
              actor: user
            )

          geofence
        end

      for index <- 1..check_in_count//1 do
        create_check_in(user, event, index)
      end

      audit_target = create_user("audit_target")
      {:ok, audit_target_membership} = Events.join_event(event.join_code, actor: audit_target)

      {:ok, _updated} =
        Events.update_member_role(audit_target_membership, %{role: :content_manager}, actor: user)

      other_user = create_user("other")
      other_event = create_event(other_user, "Other Event")
      other_poi = create_poi(other_user, other_event, 99)
      create_attachment(other_user, other_poi)
      create_check_in(other_user, other_event, 99)

      assert {:ok, payload} = ExportBuilder.build_payload(user.id)

      assert payload.subject_user_id == user.id
      assert payload.data.account.id == user.id
      assert length(payload.data.memberships) == 1
      assert length(payload.data.member_events) == 1
      assert length(payload.data.created_pois) == length(pois)
      assert length(payload.data.created_geofences) == length(geofences)
      assert length(payload.data.media_attachments) == length(pois)
      assert length(payload.data.activity_entries) >= check_in_count
      assert length(payload.data.manager_audit_entries) == 1

      exported_ids = exported_ids(payload)

      refute other_user.id in exported_ids
      refute other_event.id in exported_ids
      refute other_poi.id in exported_ids

      assert Enum.any?(payload.inventory, &(&1.section == :created_pois))
      assert Enum.any?(payload.inventory, &(&1.section == :auth_tokens))
      assert Enum.any?(payload.inventory, &(&1.section == :manager_audit_entries))
      assert Enum.all?(payload.data.created_pois, &(&1.creator_id == user.id))
      assert Enum.all?(payload.data.media_attachments, &(&1.uploader_id == user.id))
      assert Enum.all?(payload.data.manager_audit_entries, &(&1.actor_id == user.id))
    end
  end

  @spec exported_ids(map()) :: [String.t()]
  defp exported_ids(payload) do
    payload.data
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      record when is_map(record) ->
        record
        |> Map.take([:id, :user_id, :event_id, :creator_id, :uploader_id, :actor_id])
        |> Map.values()

      _ ->
        []
    end)
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "privacy_export_#{tag}_#{n}@example.com",
          display_name: "Privacy Export #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(user, name) do
    now = DateTime.utc_now(:second)

    {:ok, event} =
      Ash.create(
        Event,
        %{
          name: name,
          description: "Export test event",
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
          name: "Export POI #{index}",
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
          name: "Export Geofence #{index}",
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

  @spec create_attachment(User.t(), Platser.Map.Poi.t()) :: Platser.Media.Attachment.t()
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
end
