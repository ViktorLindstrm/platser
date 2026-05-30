defmodule Platser.Events.Changes.BroadcastJoin do
  @moduledoc """
  After a Membership is created via the :join action, creates an Activity.Entry
  and broadcasts a PubSub message. Uses after_transaction so the broadcast only
  happens after the DB transaction commits successfully.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, context) do
    actor = context.actor

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, membership} ->
          broadcast_join(membership, actor)
          {:ok, membership}

        error ->
          error
      end
    end)
  end

  @spec broadcast_join(Platser.Events.Membership.t(), Platser.Accounts.User.t() | nil) :: :ok
  defp broadcast_join(membership, actor) do
    actor_name = if actor, do: actor.display_name, else: "Someone"
    message = "#{actor_name} joined the event"

    case Platser.Activity.create_entry(
           %{
             action: :joined_event,
             subject_type: "user",
             subject_id: if(actor, do: actor.id, else: membership.user_id),
             message: message,
             event_id: membership.event_id
           },
           actor: actor,
           authorize?: false
         ) do
      {:ok, entry} ->
        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{membership.event_id}:activity",
          {:entry_added, entry}
        )

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to create activity entry for membership #{membership.id}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
