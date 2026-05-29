defmodule Platser.Dev.GpsSimulator.Movement do
  @moduledoc """
  Pure movement pattern computations for the GPS simulator.
  """

  @type pattern :: :stationary | :linear | :random_walk | :route

  @type stationary_state :: %{lat: float(), lng: float()}

  @type linear_state :: %{
          start_lat: float(),
          start_lng: float(),
          end_lat: float(),
          end_lng: float(),
          step: non_neg_integer(),
          total_steps: pos_integer()
        }

  @type random_walk_state :: %{lat: float(), lng: float(), step_size: float()}

  @type route_state :: %{
          points: [{float(), float()}],
          index: non_neg_integer()
        }

  @type pattern_state :: stationary_state() | linear_state() | random_walk_state() | route_state()

  @lat_min -90.0
  @lat_max 90.0
  @lng_min -180.0
  @lng_max 180.0

  @spec initial_state(pattern(), keyword()) :: pattern_state()
  def initial_state(:stationary, opts) do
    %{lat: Keyword.fetch!(opts, :lat), lng: Keyword.fetch!(opts, :lng)}
  end

  def initial_state(:linear, opts) do
    %{
      start_lat: Keyword.fetch!(opts, :start_lat),
      start_lng: Keyword.fetch!(opts, :start_lng),
      end_lat: Keyword.fetch!(opts, :end_lat),
      end_lng: Keyword.fetch!(opts, :end_lng),
      step: 0,
      total_steps: Keyword.get(opts, :total_steps, 20)
    }
  end

  def initial_state(:random_walk, opts) do
    %{
      lat: Keyword.fetch!(opts, :lat),
      lng: Keyword.fetch!(opts, :lng),
      step_size: Keyword.get(opts, :step_size, 0.001)
    }
  end

  def initial_state(:route, opts) do
    center_lat = Keyword.get(opts, :lat, 59.3293)
    center_lng = Keyword.get(opts, :lng, 18.0686)
    radius = Keyword.get(opts, :radius, 0.001)

    points =
      Keyword.get(
        opts,
        :points,
        [
          {center_lat, center_lng},
          {center_lat + radius, center_lng},
          {center_lat + radius, center_lng + radius},
          {center_lat, center_lng + radius}
        ]
      )

    %{points: points, index: 0}
  end

  @spec next_position(pattern(), pattern_state()) :: {{float(), float()}, pattern_state()}
  def next_position(:stationary, %{lat: lat, lng: lng} = state) do
    {{lat, lng}, state}
  end

  def next_position(
        :linear,
        %{
          start_lat: slat,
          start_lng: slng,
          end_lat: elat,
          end_lng: elng,
          step: step,
          total_steps: total
        } = state
      ) do
    t = step / total
    lat = slat + (elat - slat) * t
    lng = slng + (elng - slng) * t
    next_step = rem(step + 1, total + 1)
    {{lat, lng}, %{state | step: next_step}}
  end

  def next_position(:random_walk, %{lat: lat, lng: lng, step_size: step_size} = state) do
    delta_lat = (:rand.uniform() * 2.0 - 1.0) * step_size
    delta_lng = (:rand.uniform() * 2.0 - 1.0) * step_size
    new_lat = clamp(lat + delta_lat, @lat_min, @lat_max)
    new_lng = clamp(lng + delta_lng, @lng_min, @lng_max)
    {{new_lat, new_lng}, %{state | lat: new_lat, lng: new_lng}}
  end

  def next_position(:route, %{points: points, index: index} = state) do
    {lat, lng} = Enum.at(points, index)
    next_index = rem(index + 1, max(length(points), 1))
    {{lat, lng}, %{state | index: next_index}}
  end

  @spec current_position(pattern_state()) :: {float(), float()}
  def current_position(%{lat: lat, lng: lng}), do: {lat, lng}

  def current_position(%{
        start_lat: slat,
        start_lng: slng,
        end_lat: elat,
        end_lng: elng,
        step: step,
        total_steps: total
      }) do
    t = step / total
    {slat + (elat - slat) * t, slng + (elng - slng) * t}
  end

  def current_position(%{points: points, index: index}) do
    Enum.at(points, index)
  end

  @spec clamp(float(), float(), float()) :: float()
  defp clamp(val, min_val, max_val), do: max(min_val, min(max_val, val))
end
