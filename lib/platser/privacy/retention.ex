defmodule Platser.Privacy.Retention do
  @moduledoc """
  Default privacy-sensitive data retention cleanup.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platser.Media.Attachment
  alias Platser.Media.DiskPath
  alias Platser.Privacy.ExportStore
  alias Platser.Repo

  require Logger

  @type action :: :anonymize | :delete | :detach | :preserve
  @type data_class ::
          :check_ins | :activity_entries | :guest_accounts | :attachments | :dsar_exports
  @type policy :: %{
          data_class: data_class(),
          window_days: pos_integer(),
          action: action()
        }
  @type run_result :: %{
          run_id: Ecto.UUID.t(),
          status: :completed,
          outcome_counts: map(),
          cutoffs: map()
        }
  @type run_error :: {:error, term()}

  @check_in_days 30
  @activity_days 365
  @guest_days 30
  @attachment_days 180
  @export_days 7
  @retained_check_in_message "Check-in retained; precise location removed"

  @doc "Returns the default privacy retention policies."
  @spec policies() :: [policy()]
  def policies do
    [
      %{data_class: :check_ins, window_days: @check_in_days, action: :anonymize},
      %{data_class: :activity_entries, window_days: @activity_days, action: :delete},
      %{data_class: :guest_accounts, window_days: @guest_days, action: :anonymize},
      %{data_class: :attachments, window_days: @attachment_days, action: :detach},
      %{data_class: :dsar_exports, window_days: @export_days, action: :delete}
    ]
  end

  @doc "Returns true when the timestamp is older than the given retention window."
  @spec expired?(DateTime.t(), DateTime.t(), pos_integer()) :: boolean()
  def expired?(%DateTime{} = timestamp, %DateTime{} = now, days) when days > 0 do
    DateTime.compare(timestamp, DateTime.add(now, -days, :day)) == :lt
  end

  @doc "Runs all default retention cleanup steps and records an operator-visible run row."
  @spec run(DateTime.t()) :: {:ok, run_result()} | run_error()
  def run(now \\ DateTime.utc_now(:second)) do
    started_at = DateTime.truncate(now, :second)
    cutoffs = cutoffs(started_at)

    result =
      Multi.new()
      |> Multi.run(:attachments_selected, fn repo, _changes ->
        {:ok, repo.all(expired_attachments_query(cutoffs.attachments))}
      end)
      |> Multi.run(:attachments_files_deleted, fn _repo, changes ->
        {:ok, delete_attachment_files(changes.attachments_selected)}
      end)
      |> Multi.delete_all(:attachments_deleted, fn %{attachments_selected: attachments} ->
        attachment_ids = Enum.map(attachments, &db_uuid(&1.id))
        from(a in "media_attachments", where: a.id in ^attachment_ids)
      end)
      |> Multi.update_all(:check_ins_anonymized, check_ins_query(cutoffs.check_ins),
        set: [lat: nil, lng: nil, message: @retained_check_in_message]
      )
      |> Multi.delete_all(
        :activity_entries_deleted,
        activity_entries_query(cutoffs.activity_entries)
      )
      |> Multi.run(:guest_ids, fn repo, _changes ->
        {:ok, repo.all(stale_guest_ids_query(cutoffs.guest_accounts, started_at))}
      end)
      |> Multi.run(:guests_anonymized, fn repo, %{guest_ids: guest_ids} ->
        anonymize_guests(repo, guest_ids, started_at)
      end)
      |> Multi.run(:exports_selected, fn repo, _changes ->
        {:ok, repo.all(expired_exports_query(started_at))}
      end)
      |> Multi.run(:export_files_deleted, fn _repo, %{exports_selected: exports} ->
        {:ok, delete_export_files(exports)}
      end)
      |> Multi.delete_all(:exports_deleted, fn %{exports_selected: exports} ->
        export_ids = Enum.map(exports, &db_uuid(&1.id))
        from(e in "privacy_exports", where: e.id in ^export_ids)
      end)
      |> Repo.transaction()

    case result do
      {:ok, changes} ->
        outcome_counts = outcome_counts(changes)
        completed_at = DateTime.utc_now(:second)

        {:ok, run} =
          record_run(:completed, started_at, completed_at, cutoffs, outcome_counts, nil)

        {:ok,
         %{
           run_id: run.id,
           status: :completed,
           outcome_counts: outcome_counts,
           cutoffs: stringify_cutoffs(cutoffs)
         }}

      {:error, step, reason, _changes} ->
        failure_reason = sanitized_failure(step, reason)
        Logger.warning("Retention cleanup failed: #{failure_reason}")
        completed_at = DateTime.utc_now(:second)
        _ = record_run(:failed, started_at, completed_at, cutoffs, %{}, failure_reason)
        {:error, reason}
    end
  end

  @spec cutoffs(DateTime.t()) :: map()
  defp cutoffs(now) do
    %{
      check_ins: DateTime.add(now, -@check_in_days, :day),
      activity_entries: DateTime.add(now, -@activity_days, :day),
      guest_accounts: DateTime.add(now, -@guest_days, :day),
      attachments: DateTime.add(now, -@attachment_days, :day),
      dsar_exports: DateTime.add(now, -@export_days, :day)
    }
  end

  @spec expired_attachments_query(DateTime.t()) :: Ecto.Query.t()
  defp expired_attachments_query(cutoff) do
    from a in Attachment,
      where: a.inserted_at < ^cutoff,
      select: a
  end

  @spec check_ins_query(DateTime.t()) :: Ecto.Query.t()
  defp check_ins_query(cutoff) do
    from e in "entries",
      where:
        e.action == "checked_in" and e.inserted_at < ^cutoff and
          (not is_nil(e.lat) or not is_nil(e.lng) or e.message != ^@retained_check_in_message)
  end

  @spec activity_entries_query(DateTime.t()) :: Ecto.Query.t()
  defp activity_entries_query(cutoff) do
    from e in "entries",
      where: e.action != "checked_in" and e.inserted_at < ^cutoff
  end

  @spec stale_guest_ids_query(DateTime.t(), DateTime.t()) :: Ecto.Query.t()
  defp stale_guest_ids_query(cutoff, now) do
    from u in "users",
      as: :user,
      where:
        u.is_guest == true and is_nil(u.deleted_at) and u.inserted_at < ^cutoff and
          not exists(
            from m in "memberships",
              join: e in "events",
              on: e.id == m.event_id,
              where: m.user_id == parent_as(:user).id and e.ends_at >= ^now,
              select: 1
          ),
      select: u.id
  end

  @spec expired_exports_query(DateTime.t()) :: Ecto.Query.t()
  defp expired_exports_query(now) do
    from e in "privacy_exports",
      where: e.expires_at < ^now,
      select: %{id: e.id, path: e.path}
  end

  @spec delete_attachment_files([Attachment.t()]) :: non_neg_integer()
  defp delete_attachment_files(attachments) do
    Enum.count(attachments, fn attachment ->
      attachment
      |> DiskPath.for_attachment()
      |> delete_file()
    end)
  end

  @spec delete_export_files([map()]) :: non_neg_integer()
  defp delete_export_files(exports) do
    Enum.count(exports, fn %{id: id, path: path} ->
      expected = ExportStore.artifact_path(uuid_string(id))

      case path do
        nil -> false
        candidate -> if Path.expand(candidate) == expected, do: delete_file(expected), else: false
      end
    end)
  end

  @spec delete_file(String.t() | nil) :: boolean()
  defp delete_file(nil), do: false

  defp delete_file(path) do
    case File.rm(path) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, reason} -> raise File.Error, reason: reason, action: "remove file", path: path
    end
  end

  @spec anonymize_guests(Ecto.Repo.t(), [Ecto.UUID.t()], DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  defp anonymize_guests(_repo, [], _now) do
    {:ok,
     %{
       users_anonymized: 0,
       tokens_revoked: 0,
       activity_entries_anonymized: 0,
       poi_comments_cleared: 0,
       geofence_comments_cleared: 0
     }}
  end

  defp anonymize_guests(repo, guest_ids, now) do
    guest_id_binaries = Enum.map(guest_ids, &db_uuid/1)
    guest_id_strings = Enum.map(guest_ids, &uuid_string/1)

    {activity_entries, _} =
      repo.update_all(
        from(e in "entries", where: e.actor_id in ^guest_id_binaries),
        set: [lat: nil, lng: nil, message: "[retained guest account]"]
      )

    {poi_comments, _} =
      repo.update_all(
        from(p in "pois", where: p.creator_id in ^guest_id_binaries and not is_nil(p.comment)),
        set: [comment: nil]
      )

    {geofence_comments, _} =
      repo.update_all(
        from(g in "geofences",
          where: g.creator_id in ^guest_id_binaries and not is_nil(g.comment)
        ),
        set: [comment: nil]
      )

    {tokens, _} =
      repo.delete_all(
        from(t in "tokens",
          where: fragment("? = ANY(?)", t.subject, ^Enum.map(guest_id_strings, &"user?id=#{&1}"))
        )
      )

    {users, _} =
      repo.update_all(
        from(u in "users",
          where: u.id in ^guest_id_binaries,
          update: [
            set: [
              email: fragment("'deleted_guest_' || ?::text || '@platser.deleted'", u.id),
              display_name: "Deleted guest",
              hashed_password: nil,
              is_guest: false,
              superuser: false,
              deleted_at: ^now
            ]
          ]
        ),
        []
      )

    {:ok,
     %{
       users_anonymized: users,
       tokens_revoked: tokens,
       activity_entries_anonymized: activity_entries,
       poi_comments_cleared: poi_comments,
       geofence_comments_cleared: geofence_comments
     }}
  end

  @spec outcome_counts(map()) :: map()
  defp outcome_counts(changes) do
    %{
      "attachments_deleted" => changed_count(changes, :attachments_deleted),
      "attachment_files_deleted" => changes.attachments_files_deleted,
      "check_ins_anonymized" => changed_count(changes, :check_ins_anonymized),
      "activity_entries_deleted" => changed_count(changes, :activity_entries_deleted),
      "guest_accounts_anonymized" => changes.guests_anonymized.users_anonymized,
      "guest_tokens_revoked" => changes.guests_anonymized.tokens_revoked,
      "guest_activity_entries_anonymized" =>
        changes.guests_anonymized.activity_entries_anonymized,
      "guest_poi_comments_cleared" => changes.guests_anonymized.poi_comments_cleared,
      "guest_geofence_comments_cleared" => changes.guests_anonymized.geofence_comments_cleared,
      "dsar_exports_deleted" => changed_count(changes, :exports_deleted),
      "dsar_export_files_deleted" => changes.export_files_deleted
    }
  end

  @spec changed_count(map(), atom()) :: non_neg_integer()
  defp changed_count(changes, key) do
    case Map.fetch!(changes, key) do
      {count, _rows} -> count
      count when is_integer(count) -> count
    end
  end

  @spec db_uuid(Ecto.UUID.t() | binary()) :: binary()
  defp db_uuid(<<_::128>> = uuid), do: uuid
  defp db_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  @spec uuid_string(Ecto.UUID.t() | binary()) :: Ecto.UUID.t()
  defp uuid_string(<<_::128>> = uuid), do: Ecto.UUID.load!(uuid)
  defp uuid_string(uuid), do: uuid

  @spec record_run(
          :completed | :failed,
          DateTime.t(),
          DateTime.t(),
          map(),
          map(),
          String.t() | nil
        ) ::
          {:ok, Platser.Privacy.RetentionRun.t()} | {:error, term()}
  defp record_run(status, started_at, completed_at, cutoffs, outcome_counts, failure_reason) do
    Platser.Privacy.RetentionRun
    |> Ash.Changeset.for_create(
      :record,
      %{
        status: status,
        started_at: started_at,
        completed_at: completed_at,
        cutoffs: stringify_cutoffs(cutoffs),
        outcome_counts: outcome_counts,
        failure_reason: failure_reason
      },
      authorize?: false
    )
    |> Ash.create()
  end

  @spec stringify_cutoffs(map()) :: map()
  defp stringify_cutoffs(cutoffs) do
    Map.new(cutoffs, fn {key, value} -> {to_string(key), DateTime.to_iso8601(value)} end)
  end

  @spec sanitized_failure(atom(), term()) :: String.t()
  defp sanitized_failure(step, reason) do
    "#{step}: #{Exception.message(Ash.Error.to_error_class(reason))}"
  rescue
    _ -> "#{step}: retention cleanup failed"
  end
end
