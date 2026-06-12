defmodule Platser.Privacy.AccountDeletion do
  @moduledoc """
  Account deletion/anonymization boundary.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platser.Accounts.User
  alias Platser.Privacy.Deletion
  alias Platser.Repo

  @type deletion_result :: %{deletion: Deletion.t(), user: User.t(), outcome_counts: map()}
  @type delete_error :: :already_deleted | term()

  @redacted_message "[deleted account]"

  @spec delete_account(User.t()) :: {:ok, deletion_result()} | {:error, delete_error()}
  def delete_account(%User{deleted_at: %DateTime{}}), do: {:error, :already_deleted}

  def delete_account(%User{} = user) do
    now = DateTime.utc_now(:second)
    user_id = user.id

    multi =
      Multi.new()
      |> Multi.update_all(:activity_entries, activity_entries_query(user_id),
        set: [message: @redacted_message, lat: nil, lng: nil]
      )
      |> Multi.update_all(:poi_comments, poi_comments_query(user_id), set: [comment: nil])
      |> Multi.update_all(:geofence_comments, geofence_comments_query(user_id),
        set: [comment: nil]
      )
      |> Multi.delete_all(:tokens, tokens_query(user_id))
      |> Multi.run(:user, fn _repo, _changes ->
        case user
             |> Ash.Changeset.for_update(:anonymize_for_deletion, %{deleted_at: now},
               authorize?: false
             )
             |> Ash.update(return_notifications?: true) do
          {:ok, anonymized_user, notifications} ->
            {:ok, %{record: anonymized_user, notifications: notifications}}

          {:error, _reason} = error ->
            error
        end
      end)
      |> Multi.run(:deletion, fn _repo, changes ->
        outcome_counts = outcome_counts(changes)

        case Deletion
             |> Ash.Changeset.for_create(
               :record,
               %{
                 user_id: user_id,
                 requested_by_id: user_id,
                 status: :completed,
                 requested_at: now,
                 completed_at: now,
                 outcome_counts: outcome_counts
               },
               authorize?: false
             )
             |> Ash.create(return_notifications?: true) do
          {:ok, deletion, notifications} ->
            {:ok, %{record: deletion, notifications: notifications}}

          {:error, _reason} = error ->
            error
        end
      end)

    case Repo.transaction(multi) do
      {:ok, %{deletion: deletion, user: anonymized_user} = changes} ->
        _ = Ash.Notifier.notify(anonymized_user.notifications ++ deletion.notifications)

        {:ok,
         %{
           deletion: deletion.record,
           user: anonymized_user.record,
           outcome_counts: outcome_counts(changes)
         }}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @spec activity_entries_query(Ecto.UUID.t() | String.t()) :: Ecto.Query.t()
  defp activity_entries_query(user_id) do
    from e in "entries",
      where: e.actor_id == type(^user_id, :binary_id)
  end

  @spec poi_comments_query(Ecto.UUID.t() | String.t()) :: Ecto.Query.t()
  defp poi_comments_query(user_id) do
    from p in "pois",
      where: p.creator_id == type(^user_id, :binary_id)
  end

  @spec geofence_comments_query(Ecto.UUID.t() | String.t()) :: Ecto.Query.t()
  defp geofence_comments_query(user_id) do
    from g in "geofences",
      where: g.creator_id == type(^user_id, :binary_id)
  end

  @spec tokens_query(Ecto.UUID.t() | String.t()) :: Ecto.Query.t()
  defp tokens_query(user_id) do
    subject_suffix = encode_id(user_id)

    from t in "tokens",
      where: like(t.subject, ^"%#{subject_suffix}")
  end

  @spec outcome_counts(map()) :: map()
  defp outcome_counts(changes) do
    %{
      "activity_entries_anonymized" => changed_count(changes, :activity_entries),
      "poi_comments_cleared" => changed_count(changes, :poi_comments),
      "geofence_comments_cleared" => changed_count(changes, :geofence_comments),
      "tokens_revoked" => changed_count(changes, :tokens),
      "users_anonymized" => 1
    }
  end

  @spec changed_count(map(), atom()) :: non_neg_integer()
  defp changed_count(changes, key) do
    case Map.fetch(changes, key) do
      {:ok, {count, _rows}} -> count
      :error -> 0
    end
  end

  @spec encode_id(Ecto.UUID.t() | binary()) :: String.t()
  defp encode_id(<<_::128>> = id), do: Ecto.UUID.load!(id)
  defp encode_id(id) when is_binary(id), do: id
end
