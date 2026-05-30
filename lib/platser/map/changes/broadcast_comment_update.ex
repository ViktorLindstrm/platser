defmodule Platser.Map.Changes.BroadcastCommentUpdate do
  @moduledoc """
  Broadcasts map-object updates and creates activity entries when a comment changes.
  """

  use Ash.Resource.Change

  alias Platser.Map.Geofence
  alias Platser.Map.Poi

  @impl Ash.Resource.Change
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, context) do
    actor = context.actor

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, %Poi{} = poi} ->
          broadcast_comment_update(poi, actor)
          {:ok, poi}

        {:ok, %Geofence{} = geofence} ->
          broadcast_comment_update(geofence, actor)
          {:ok, geofence}

        error ->
          error
      end
    end)
  end

  @spec broadcast_comment_update(Poi.t(), Platser.Accounts.User.t() | nil) :: :ok
  defp broadcast_comment_update(%Poi{} = poi, actor) do
    broadcast_map_update(poi, {:poi_updated, poi})
    broadcast_activity_entry("poi", poi.id, poi.event_id, poi.name, actor)
  end

  @spec broadcast_comment_update(Geofence.t(), Platser.Accounts.User.t() | nil) :: :ok
  defp broadcast_comment_update(%Geofence{} = geofence, actor) do
    broadcast_map_update(geofence, {:geofence_updated, geofence})
    broadcast_activity_entry("geofence", geofence.id, geofence.event_id, geofence.name, actor)
  end

  @spec broadcast_map_update(Poi.t() | Geofence.t(), tuple()) :: :ok
  defp broadcast_map_update(item, message) do
    Phoenix.PubSub.broadcast(
      Platser.PubSub,
      "event:#{item.event_id}:map_objects",
      message
    )
  end

  @spec broadcast_activity_entry(
          String.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          Platser.Accounts.User.t() | nil
        ) :: :ok
  defp broadcast_activity_entry(subject_type, subject_id, event_id, item_name, actor) do
    actor_name = if actor, do: actor.display_name, else: "Someone"
    message = "#{actor_name} commented on #{item_name}"

    case Platser.Activity.create_entry(
           %{
             action: :comment_added,
             subject_type: subject_type,
             subject_id: subject_id,
             message: message,
             event_id: event_id
           },
           actor: actor,
           authorize?: false
         ) do
      {:ok, entry} ->
        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{event_id}:activity",
          {:entry_added, entry}
        )

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to create comment activity entry for #{subject_type} #{subject_id}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
