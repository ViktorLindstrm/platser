defmodule Platser.Activity do
  use Ash.Domain,
    otp_app: :platser

  resources do
    resource Platser.Activity.Entry do
      define :list_entries_for_event, action: :list_by_event, args: [:event_id]
      define :create_entry, action: :create
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
end
