defmodule Platser.Map.Changes.BroadcastPublish do
  @moduledoc """
  After a POI is published, creates an Activity.Entry and broadcasts
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
        {:ok, poi} ->
          broadcast_publish(poi, actor)
          {:ok, poi}

        error ->
          error
      end
    end)
  end

  @spec broadcast_publish(Platser.Map.Poi.t(), Platser.Accounts.User.t() | nil) :: :ok
  defp broadcast_publish(poi, actor) do
    Phoenix.PubSub.broadcast(
      Platser.PubSub,
      "event:#{poi.event_id}:map_objects",
      {:poi_added, poi}
    )

    actor_name = if actor, do: actor.display_name, else: "Someone"
    message = "#{actor_name} published a POI: #{poi.name}"

    case Platser.Activity.create_entry(
           %{
             action: :poi_published,
             subject_type: "poi",
             subject_id: poi.id,
             message: message,
             event_id: poi.event_id
           },
           actor: actor,
           authorize?: false
         ) do
      {:ok, entry} ->
        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{poi.event_id}:activity",
          {:entry_added, entry}
        )

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to create activity entry for poi #{poi.id}: #{inspect(reason)}")
    end

    :ok
  end
end
