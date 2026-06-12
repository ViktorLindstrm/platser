defmodule Platser.PrivacyRetentionPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap
  alias Platser.Media
  alias Platser.Privacy
  alias Platser.Privacy.ExportStore
  alias Platser.Privacy.Retention
  alias Platser.Repo

  @retained_check_in_message "Check-in retained; precise location removed"

  property "retention cleanup applies default windows and is safe to rerun" do
    check all(
            check_in_age <- StreamData.integer(31..120),
            fresh_check_in_age <- StreamData.integer(0..29),
            activity_age <- StreamData.integer(366..720),
            attachment_age <- StreamData.integer(181..360),
            max_runs: 5
          ) do
      export_root =
        Path.join(System.tmp_dir!(), "platser-retention-#{System.unique_integer([:positive])}")

      old_root = Application.get_env(:platser, :privacy_exports_root)
      Application.put_env(:platser, :privacy_exports_root, export_root)
      on_exit(fn -> restore_export_root(old_root, export_root) end)

      now = DateTime.utc_now(:second)
      user = create_user("retention")
      event = create_event(user, "Retention Event", now)
      old_check_in = create_check_in(user, event, check_in_age, now)
      fresh_check_in = create_check_in(user, event, fresh_check_in_age, now)
      old_activity = create_activity(user, event, activity_age, now)
      fresh_activity = create_activity(user, event, 1, now)
      {_attachment, attachment_path} = create_attachment(user, event, attachment_age, now)
      {export_id, export_path} = create_export(user, now)
      stale_guest = create_stale_guest(user, now)
      active_guest = create_active_guest(user, now)

      assert File.exists?(attachment_path)
      assert File.exists?(export_path)

      assert {:ok, first} = Privacy.run_retention()

      assert first.outcome_counts["check_ins_anonymized"] >= 1
      assert first.outcome_counts["activity_entries_deleted"] >= 1
      assert first.outcome_counts["attachments_deleted"] >= 1
      assert first.outcome_counts["dsar_exports_deleted"] >= 1
      assert first.outcome_counts["guest_accounts_anonymized"] >= 1

      old_check_in_row = entry_row(old_check_in.id)
      assert old_check_in_row.lat == nil
      assert old_check_in_row.lng == nil
      assert old_check_in_row.message == @retained_check_in_message

      fresh_check_in_row = entry_row(fresh_check_in.id)
      assert is_float(fresh_check_in_row.lat)
      assert is_float(fresh_check_in_row.lng)

      assert is_nil(entry_row(old_activity.id))
      refute is_nil(entry_row(fresh_activity.id))
      refute File.exists?(attachment_path)
      refute File.exists?(export_path)

      assert Repo.aggregate(
               from(e in "privacy_exports", where: e.id == type(^export_id, :binary_id)),
               :count
             ) == 0

      stale_guest = Ash.get!(User, stale_guest.id, authorize?: false)
      active_guest = Ash.get!(User, active_guest.id, authorize?: false)
      assert stale_guest.deleted_at
      assert stale_guest.is_guest == false
      assert active_guest.is_guest == true
      assert is_nil(active_guest.deleted_at)

      assert {:ok, second} = Privacy.run_retention()
      assert second.outcome_counts["check_ins_anonymized"] == 0
      assert second.outcome_counts["activity_entries_deleted"] == 0
      assert second.outcome_counts["attachments_deleted"] == 0
      assert second.outcome_counts["dsar_exports_deleted"] == 0
      assert second.outcome_counts["guest_accounts_anonymized"] == 0
    end
  end

  property "policy expiry predicate follows generated date boundaries" do
    check all(
            days <- StreamData.integer(1..365),
            offset <- StreamData.integer(-2..2),
            max_runs: 25
          ) do
      now = ~U[2026-06-12 12:00:00Z]
      timestamp = DateTime.add(now, -(days + offset), :day)

      assert Retention.expired?(timestamp, now, days) ==
               (DateTime.compare(timestamp, DateTime.add(now, -days, :day)) == :lt)
    end
  end

  @spec restore_export_root(String.t() | nil, String.t()) :: :ok
  defp restore_export_root(nil, root) do
    Application.delete_env(:platser, :privacy_exports_root)
    File.rm_rf!(root)
    :ok
  end

  defp restore_export_root(root, temp_root) do
    Application.put_env(:platser, :privacy_exports_root, root)
    File.rm_rf!(temp_root)
    :ok
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "privacy_retention_#{tag}_#{n}@example.com",
          display_name: "Retention #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_guest(String.t()) :: User.t()
  defp create_guest(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{display_name: "Guest #{tag} #{n}"},
        action: :create_guest,
        authorize?: false
      )

    user
  end

  @spec create_event(User.t(), String.t(), DateTime.t()) :: Event.t()
  defp create_event(user, name, now) do
    {:ok, event} =
      Ash.create(
        Event,
        %{
          name: name,
          description: "Retention test event",
          starts_at: DateTime.add(now, -3600),
          ends_at: DateTime.add(now, 3600)
        },
        actor: user
      )

    event
  end

  @spec create_ended_event(User.t(), DateTime.t()) :: Event.t()
  defp create_ended_event(user, now) do
    event = create_event(user, "Ended Retention Event", now)

    Repo.update_all(
      from(e in "events", where: e.id == type(^event.id, :binary_id)),
      set: [starts_at: DateTime.add(now, -60, :day), ends_at: DateTime.add(now, -31, :day)]
    )

    event
  end

  @spec create_check_in(User.t(), Event.t(), non_neg_integer(), DateTime.t()) ::
          Platser.Activity.Entry.t()
  defp create_check_in(user, event, age_days, now) do
    {:ok, entry} =
      Activity.create_check_in(
        %{
          event_id: event.id,
          lat: 59.0,
          lng: 18.0,
          message: "Check-in #{age_days}"
        },
        actor: user
      )

    set_entry_inserted_at(entry.id, DateTime.add(now, -age_days, :day))
    entry
  end

  @spec create_activity(User.t(), Event.t(), non_neg_integer(), DateTime.t()) ::
          Platser.Activity.Entry.t()
  defp create_activity(user, event, age_days, now) do
    {:ok, entry} =
      Activity.create_entry(
        %{
          action: :comment_added,
          subject_type: "poi",
          subject_id: Ecto.UUID.generate(),
          event_id: event.id,
          message: "Activity #{age_days}"
        },
        actor: user
      )

    set_entry_inserted_at(entry.id, DateTime.add(now, -age_days, :day))
    entry
  end

  @spec create_attachment(User.t(), Event.t(), non_neg_integer(), DateTime.t()) ::
          {Platser.Media.Attachment.t(), String.t()}
  defp create_attachment(user, event, age_days, now) do
    poi = create_poi(user, event)
    stored_filename = "#{Ecto.UUID.generate()}.jpg"
    path = "/uploads/#{poi.id}/#{stored_filename}"

    {:ok, attachment} =
      Media.create_attachment(
        %{
          filename: "image.jpg",
          stored_filename: stored_filename,
          content_type: "image/jpeg",
          path: path,
          poi_id: poi.id
        },
        actor: user
      )

    disk_path = Platser.Media.DiskPath.for_attachment(attachment)
    File.mkdir_p!(Path.dirname(disk_path))
    File.write!(disk_path, "image")

    Repo.update_all(
      from(a in "media_attachments", where: a.id == type(^attachment.id, :binary_id)),
      set: [inserted_at: DateTime.add(now, -age_days, :day)]
    )

    {attachment, disk_path}
  end

  @spec create_poi(User.t(), Event.t()) :: Platser.Map.Poi.t()
  defp create_poi(user, event) do
    {:ok, poi} =
      PlatserMap.create_poi(
        %{
          name: "Retention POI",
          description: "POI",
          category: :viewpoint,
          color: "#3B82F6",
          location: %Geo.Point{coordinates: {18.0, 59.0}, srid: 4326},
          event_id: event.id
        },
        actor: user
      )

    poi
  end

  @spec create_export(User.t(), DateTime.t()) :: {Ecto.UUID.t(), String.t()}
  defp create_export(user, now) do
    export_id = Ecto.UUID.generate()
    path = ExportStore.artifact_path(export_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")

    Repo.insert_all("privacy_exports", [
      %{
        id: Ecto.UUID.dump!(export_id),
        user_id: Ecto.UUID.dump!(user.id),
        status: "completed",
        format: "application/json",
        path: path,
        size_bytes: 2,
        checksum: "sha256",
        requested_at: DateTime.add(now, -10, :day),
        completed_at: DateTime.add(now, -10, :day),
        expires_at: DateTime.add(now, -1, :day)
      }
    ])

    {export_id, path}
  end

  @spec create_stale_guest(User.t(), DateTime.t()) :: User.t()
  defp create_stale_guest(admin, now) do
    guest = create_guest("stale")
    event = create_ended_event(admin, now)
    {:ok, _membership} = Events.join_event(event.join_code, actor: guest)

    Repo.update_all(
      from(u in "users", where: u.id == type(^guest.id, :binary_id)),
      set: [inserted_at: DateTime.add(now, -45, :day)]
    )

    guest
  end

  @spec create_active_guest(User.t(), DateTime.t()) :: User.t()
  defp create_active_guest(admin, now) do
    guest = create_guest("active")
    event = create_event(admin, "Active Guest Event", now)
    {:ok, _membership} = Events.join_event(event.join_code, actor: guest)

    Repo.update_all(
      from(u in "users", where: u.id == type(^guest.id, :binary_id)),
      set: [inserted_at: DateTime.add(now, -45, :day)]
    )

    guest
  end

  @spec set_entry_inserted_at(Ecto.UUID.t(), DateTime.t()) :: :ok
  defp set_entry_inserted_at(entry_id, inserted_at) do
    Repo.update_all(
      from(e in "entries", where: e.id == type(^entry_id, :binary_id)),
      set: [inserted_at: inserted_at]
    )

    :ok
  end

  @spec entry_row(Ecto.UUID.t()) :: map() | nil
  defp entry_row(entry_id) do
    Repo.one(
      from e in "entries",
        where: e.id == type(^entry_id, :binary_id),
        select: %{message: e.message, lat: e.lat, lng: e.lng}
    )
  end
end
