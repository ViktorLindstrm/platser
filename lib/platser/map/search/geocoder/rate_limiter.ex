defmodule Platser.Map.Search.Geocoder.RateLimiter do
  @moduledoc false

  use GenServer

  @type monotonic_millisecond :: integer()

  @min_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec wait(non_neg_integer()) :: :ok
  def wait(interval_ms \\ @min_interval_ms) do
    GenServer.call(__MODULE__, {:wait, interval_ms}, :infinity)
  end

  @impl true
  @spec init(nil) :: {:ok, monotonic_millisecond() | nil}
  def init(nil), do: {:ok, nil}

  @impl true
  @spec handle_call({:wait, non_neg_integer()}, GenServer.from(), monotonic_millisecond() | nil) ::
          {:reply, :ok, monotonic_millisecond()}
  def handle_call({:wait, interval_ms}, _from, last_request_at) do
    now = System.monotonic_time(:millisecond)

    sleep_ms =
      case last_request_at do
        nil -> 0
        last -> max(interval_ms - (now - last), 0)
      end

    if sleep_ms > 0 do
      Process.sleep(sleep_ms)
    end

    {:reply, :ok, System.monotonic_time(:millisecond)}
  end
end
