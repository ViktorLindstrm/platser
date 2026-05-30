defmodule Platser.Events.Changes.BroadcastEventUpdate do
  @moduledoc """
  After an event update, broadcasts a PubSub message so all connected clients
  can refresh the event details. Uses after_transaction so the broadcast only
  happens after the DB transaction commits successfully.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, event} ->
          broadcast_event_update(event)
          {:ok, event}

        error ->
          error
      end
    end)
  end

  @spec broadcast_event_update(Platser.Events.Event.t()) :: :ok
  defp broadcast_event_update(event) do
    Phoenix.PubSub.broadcast(
      Platser.PubSub,
      "event:#{event.id}:settings",
      {:event_updated, event}
    )

    :ok
  end
end
