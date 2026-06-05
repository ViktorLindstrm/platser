defmodule Platser.Location do
  @moduledoc """
  Context for live location operations: Presence management and
  geofence entry/exit detection.
  """

  import Ecto.Query

  alias Platser.Activity
  alias Platser.EventPresence
  alias Platser.Repo

  @type location_params :: %{
          lat: float(),
          lng: float(),
          accuracy: float() | nil,
          heading: float() | nil
        }

  @wgs84_lat_min -90.0
  @wgs84_lat_max 90.0
  @wgs84_lng_min -180.0
  @wgs84_lng_max 180.0

  @doc """
  Returns true when `lat` and `lng` are within WGS-84 bounds.
  """
  @spec valid_coords?(float(), float()) :: boolean()
  def valid_coords?(lat, lng) do
    is_float(lat) and is_float(lng) and
      lat >= @wgs84_lat_min and lat <= @wgs84_lat_max and
      lng >= @wgs84_lng_min and lng <= @wgs84_lng_max
  end

  @doc """
  Updates the caller's Phoenix Presence entry with the new location.

  Steps:
  1. Validate coordinates.
  2. Query PostGIS for public geofences containing the point.
  3. Compute geofence entry/exit transitions vs the previous Presence metadata.
  4. Create Activity entries for transitions and broadcast them.
  5. Call `EventPresence.track/4` (first call) or `EventPresence.update/4` (subsequent calls).

  Returns `{:ok, new_meta}` on success, `{:error, reason}` on validation failure.
  """
  @spec update_presence(
          pid :: pid(),
          event_id :: String.t(),
          user :: Platser.Accounts.User.t(),
          params :: location_params(),
          already_tracked? :: boolean()
        ) :: {:ok, EventPresence.location_meta()} | {:error, :invalid_coords}
  def update_presence(pid, event_id, user, params, already_tracked?) do
    lat = params.lat
    lng = params.lng

    unless valid_coords?(lat, lng) do
      {:error, :invalid_coords}
    else
      accuracy = params[:accuracy]
      heading = params[:heading]
      topic = EventPresence.topic(event_id)

      new_geofence_ids = geofences_containing(event_id, lat, lng)
      old_geofence_ids = previous_geofence_ids(topic, user.id)

      entered = new_geofence_ids -- old_geofence_ids
      exited = old_geofence_ids -- new_geofence_ids

      broadcast_geofence_transitions(entered, exited, event_id, user)

      meta = %{
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        heading: heading,
        timestamp: System.system_time(:millisecond),
        geofence_ids: new_geofence_ids,
        display_name: user.display_name,
        is_simulated: Map.get(user, :is_simulated, false)
      }

      if already_tracked? do
        EventPresence.update(pid, topic, user.id, meta)
      else
        EventPresence.track(pid, topic, user.id, meta)
      end

      {:ok, meta}
    end
  end

  @doc """
  Returns IDs of public geofences whose geometry contains the given point.
  Uses PostGIS `ST_Within` for regular geofences and includes the event
  boundary with `ST_Covers` so edge points count as inside.
  """
  @spec geofences_containing(String.t(), float(), float()) :: [String.t()]
  def geofences_containing(event_id, lat, lng) do
    regular_ids = regular_geofences_containing(event_id, lat, lng)
    boundary_id = boundary_geofence_id(event_id, lat, lng)
    boundary_ids = if is_nil(boundary_id), do: nil, else: boundary_id

    regular_ids
    |> append_boundary_id(boundary_ids)
    |> Enum.uniq()
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      manual_geofences_containing(event_id, lat, lng)
  end

  @doc """
  Returns true when the coordinate lies inside the event boundary geofence.
  Boundary edges count as inside.
  """
  @spec in_event_boundary?(String.t(), %{lat: float(), lng: float()}) :: boolean()
  def in_event_boundary?(event_id, %{lat: lat, lng: lng}) do
    boundary_geofence_id(event_id, lat, lng) != nil
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      manual_boundary_geofence_id(event_id, lat, lng) != nil
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec previous_geofence_ids(String.t(), String.t()) :: [String.t()]
  defp previous_geofence_ids(topic, user_id) do
    case EventPresence.list(topic) do
      %{^user_id => %{metas: [meta | _]}} ->
        Map.get(meta, :geofence_ids, [])

      _ ->
        []
    end
  end

  @spec regular_geofences_containing(String.t(), float(), float()) :: [String.t()]
  defp regular_geofences_containing(event_id, lat, lng) do
    Repo.all(
      from g in "geofences",
        where: g.event_id == type(^event_id, :binary_id),
        where: g.visibility == "public",
        where:
          fragment(
            "ST_Within(ST_SetSRID(ST_MakePoint(?, ?), 4326), ?)",
            type(^lng, :float),
            type(^lat, :float),
            g.geometry
          ),
        select: type(g.id, :binary_id)
    )
  end

  @spec boundary_geofence_id(String.t(), float(), float()) :: String.t() | nil
  defp boundary_geofence_id(event_id, lat, lng) do
    Repo.one(
      from g in "geofences",
        where: g.event_id == type(^event_id, :binary_id),
        where: g.visibility == "public",
        where: g.purpose == "boundary",
        where:
          fragment(
            "ST_Covers(?, ST_SetSRID(ST_MakePoint(?, ?), 4326))",
            g.geometry,
            type(^lng, :float),
            type(^lat, :float)
          ),
        select: type(g.id, :binary_id)
    )
  end

  @spec append_boundary_id([String.t()], String.t() | nil) :: [String.t()]
  defp append_boundary_id(ids, nil), do: ids
  defp append_boundary_id(ids, boundary_id), do: [boundary_id | ids]

  @spec manual_geofences_containing(String.t(), float(), float()) :: [String.t()]
  defp manual_geofences_containing(event_id, lat, lng) do
    Repo.all(
      from g in "geofences",
        where: g.event_id == type(^event_id, :binary_id),
        where: g.visibility == "public",
        select: %{id: type(g.id, :binary_id), geometry: g.geometry, purpose: g.purpose}
    )
    |> Enum.flat_map(fn %{id: id, geometry: geometry, purpose: purpose} ->
      inclusive? = purpose == "boundary"

      if geometry_contains_point?(geometry, lat, lng, inclusive?) do
        [id]
      else
        []
      end
    end)
  end

  @spec manual_boundary_geofence_id(String.t(), float(), float()) :: String.t() | nil
  defp manual_boundary_geofence_id(event_id, lat, lng) do
    Repo.one(
      from g in "geofences",
        where: g.event_id == type(^event_id, :binary_id),
        where: g.visibility == "public",
        where: g.purpose == "boundary",
        select: %{id: type(g.id, :binary_id), geometry: g.geometry}
    )
    |> case do
      nil ->
        nil

      %{id: id, geometry: geometry} ->
        if geometry_contains_point?(geometry, lat, lng, true), do: id, else: nil

      _ ->
        nil
    end
  end

  @spec geometry_contains_point?(term(), float(), float(), boolean()) :: boolean()
  defp geometry_contains_point?(geometry, lat, lng, inclusive?) do
    with {:ok, %Geo.Polygon{coordinates: [ring | _]}} <- normalize_polygon(geometry) do
      ring_contains_point?(ring, lng, lat, inclusive?)
    else
      _ -> false
    end
  end

  @spec normalize_polygon(term()) :: {:ok, Geo.Polygon.t()} | :error
  defp normalize_polygon(%Geo.Polygon{} = polygon), do: {:ok, polygon}

  defp normalize_polygon(geometry) when is_map(geometry) do
    case Geo.JSON.decode(geometry) do
      {:ok, %Geo.Polygon{} = polygon} -> {:ok, polygon}
      _ -> :error
    end
  end

  defp normalize_polygon(_), do: :error

  @spec ring_contains_point?([{float(), float()}], float(), float(), boolean()) :: boolean()
  defp ring_contains_point?(ring, x, y, inclusive?) when length(ring) >= 3 do
    segments = Enum.zip(ring, tl(ring) ++ [hd(ring)])

    Enum.reduce_while(segments, false, fn {start, finish}, inside ->
      if point_on_segment?({x, y}, start, finish) do
        if inclusive?, do: {:halt, true}, else: {:halt, false}
      else
        {x1, y1} = start
        {x2, y2} = finish

        intersects? =
          y1 > y != y2 > y and
            x < x1 + (x2 - x1) * (y - y1) / (y2 - y1)

        {:cont, if(intersects?, do: !inside, else: inside)}
      end
    end)
  end

  defp ring_contains_point?(_ring, _x, _y, _inclusive?), do: false

  @spec point_on_segment?({float(), float()}, {float(), float()}, {float(), float()}) ::
          boolean()
  defp point_on_segment?({x, y}, {x1, y1}, {x2, y2}) do
    cross = (y - y1) * (x2 - x1) - (x - x1) * (y2 - y1)

    abs(cross) <= 1.0e-9 and
      x >= min(x1, x2) - 1.0e-9 and
      x <= max(x1, x2) + 1.0e-9 and
      y >= min(y1, y2) - 1.0e-9 and
      y <= max(y1, y2) + 1.0e-9
  end

  @spec broadcast_geofence_transitions(
          [String.t()],
          [String.t()],
          String.t(),
          Platser.Accounts.User.t()
        ) :: :ok
  defp broadcast_geofence_transitions([], [], _event_id, _user), do: :ok

  defp broadcast_geofence_transitions(entered, exited, event_id, user) do
    geofence_ids = Enum.uniq(entered ++ exited)

    geofence_names =
      Repo.all(
        from g in "geofences",
          where: g.id in type(^geofence_ids, {:array, :binary_id}),
          select: {type(g.id, :binary_id), g.name}
      )
      |> Map.new()

    for geofence_id <- entered do
      name = Map.get(geofence_names, geofence_id, "a geofence")

      create_geofence_activity(
        :entered_geofence,
        geofence_id,
        "#{user.display_name} entered #{name}",
        event_id,
        user
      )
    end

    for geofence_id <- exited do
      name = Map.get(geofence_names, geofence_id, "a geofence")

      create_geofence_activity(
        :exited_geofence,
        geofence_id,
        "#{user.display_name} left #{name}",
        event_id,
        user
      )
    end

    :ok
  end

  @spec create_geofence_activity(atom(), String.t(), String.t(), String.t(), map()) :: :ok
  defp create_geofence_activity(action, geofence_id, message, event_id, user) do
    case Activity.create_entry(
           %{
             action: action,
             subject_type: "geofence",
             subject_id: geofence_id,
             message: message,
             event_id: event_id
           },
           actor: user,
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
          "Failed to create geofence activity [#{action}] for geofence #{geofence_id}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
