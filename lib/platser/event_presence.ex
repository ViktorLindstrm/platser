defmodule Platser.EventPresence do
  @moduledoc """
  Phoenix Presence for tracking live member locations per event.

  Topic: `event:{event_id}:locations`

  Each user is tracked by their UUID string as the presence key.
  Metadata shape:
    %{
      lat: float(),
      lng: float(),
      accuracy: float() | nil,
      heading: float() | nil,
      timestamp: integer(),         # Unix ms
      geofence_ids: [String.t()],   # IDs of public geofences currently containing this user
      display_name: String.t(),
      is_simulated: boolean()
    }
  """

  use Phoenix.Presence,
    otp_app: :platser,
    pubsub_server: Platser.PubSub

  @type location_meta :: %{
          lat: float(),
          lng: float(),
          accuracy: float() | nil,
          heading: float() | nil,
          timestamp: integer(),
          geofence_ids: [String.t()],
          display_name: String.t(),
          is_simulated: boolean()
        }

  @doc "Returns the topic string for a given event ID."
  @spec topic(String.t()) :: String.t()
  def topic(event_id), do: "event:#{event_id}:locations"

  @doc """
  Returns current presence for a topic as a flat map of
  `user_id => latest_meta`.  For users with multiple sessions,
  the meta with the largest timestamp wins.
  """
  @spec list_locations(String.t()) :: %{String.t() => location_meta()}
  def list_locations(event_id) do
    topic(event_id)
    |> list()
    |> Map.new(fn {user_id, %{metas: metas}} ->
      latest = Enum.max_by(metas, & &1.timestamp, fn -> %{timestamp: 0} end)
      {user_id, latest}
    end)
  end
end
