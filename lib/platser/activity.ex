defmodule Platser.Activity do
  use Ash.Domain,
    otp_app: :platser

  require Ash.Query

  @type feed_filter :: :all | :check_ins | :geofence_events | :published_items | :comments

  resources do
    resource Platser.Activity.Entry do
      define :list_entries_for_event, action: :list_by_event, args: [:event_id]
      define :list_entries_for_subject, action: :list_by_subject, args: [:subject_id]
      define :list_check_ins_for_event, action: :list_check_ins_by_event, args: [:event_id]
      define :create_entry, action: :create
      define :create_check_in, action: :check_in
    end
  end

  @doc """
  Counts how many entries in `entries` have `inserted_at` strictly after `last_read_at`.

  Both timestamps are compared at second precision to account for the
  `:utc_datetime` storage type of `inserted_at`. Entries created in the
  same second as `last_read_at` are considered read.
  """
  @spec count_unread_since([Platser.Activity.Entry.t()], DateTime.t()) :: non_neg_integer()
  def count_unread_since(entries, last_read_at) do
    boundary = DateTime.truncate(last_read_at, :second)

    Enum.count(entries, fn entry ->
      DateTime.compare(entry.inserted_at, boundary) == :gt
    end)
  end

  @spec list_entries_for_event_with_filter(
          Ecto.UUID.t(),
          Platser.Accounts.User.t(),
          feed_filter()
        ) ::
          {:ok, [Platser.Activity.Entry.t()]} | {:error, term()}
  def list_entries_for_event_with_filter(event_id, actor, filter) do
    Platser.Activity.Entry
    |> Ash.Query.for_read(:list_by_event, %{event_id: event_id})
    |> filter_activity_entries(filter)
    |> Ash.read(actor: actor)
  end

  @spec filter_activity_entries(term(), feed_filter()) :: term()
  defp filter_activity_entries(query, :all), do: query

  defp filter_activity_entries(query, filter) do
    actions = activity_filter_actions(filter)
    Ash.Query.filter(query, action in ^actions)
  end

  @spec activity_filter_actions(feed_filter()) :: [atom()]
  defp activity_filter_actions(:check_ins), do: [:checked_in]
  defp activity_filter_actions(:geofence_events), do: [:entered_geofence, :exited_geofence]
  defp activity_filter_actions(:published_items), do: [:poi_published, :geofence_published]
  defp activity_filter_actions(:comments), do: [:comment_added]
end
