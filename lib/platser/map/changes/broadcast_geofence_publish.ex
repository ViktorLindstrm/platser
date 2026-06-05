defmodule Platser.Map.Changes.BroadcastGeofencePublish do
  @moduledoc """
  After a Geofence is published, creates an Activity.Entry and broadcasts
  PubSub messages. Uses after_transaction so broadcasts only happen
  after the DB transaction commits successfully.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, context) do
    actor = context.actor

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, geofence} ->
          broadcast_publish(geofence, actor)
          {:ok, geofence}

        error ->
          error
      end
    end)
  end

  @spec broadcast_publish(Platser.Map.Geofence.t(), Platser.Accounts.User.t() | nil) :: :ok
  defp broadcast_publish(geofence, actor) do
    Phoenix.PubSub.broadcast(
      Platser.PubSub,
      "event:#{geofence.event_id}:map_objects",
      {:geofence_added, geofence}
    )

    actor_name = if actor, do: actor.display_name, else: "Someone"
    purpose_label = geofence.purpose |> to_string() |> String.replace("_", " ")
    message = "#{actor_name} added a #{purpose_label}: #{geofence.name}"

    case Platser.Activity.create_entry(
           %{
             action: :geofence_published,
             subject_type: "geofence",
             subject_id: geofence.id,
             message: message,
             event_id: geofence.event_id
           },
           actor: actor,
           authorize?: false
         ) do
      {:ok, entry} ->
        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{geofence.event_id}:activity",
          {:entry_added, entry}
        )

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to create activity entry for geofence #{geofence.id}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
