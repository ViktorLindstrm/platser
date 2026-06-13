defmodule Platser.Map.Search.Geocoder.Cache do
  @moduledoc false

  use GenServer

  @type key :: String.t()
  @type value :: term()
  @type fetch_result :: {:ok, value()} | {:error, term()}
  @type entry :: %{value: value(), expires_at: integer(), inserted_at: integer()}
  @type state :: %{entries: %{optional(key()) => entry()}, sequence: non_neg_integer()}

  @default_ttl_ms 60_000
  @default_max_entries 256

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec fetch(key(), (-> fetch_result())) :: fetch_result()
  def fetch(key, fun) when is_binary(key) and is_function(fun, 0) do
    if enabled?() do
      case call({:get, key}) do
        {:ok, {:hit, value}} ->
          {:ok, value}

        {:ok, :miss} ->
          fetch_and_store(key, fun)

        :unavailable ->
          fun.()
      end
    else
      fun.()
    end
  end

  @spec clear() :: :ok
  def clear do
    case call(:clear) do
      {:ok, :ok} -> :ok
      :unavailable -> :ok
    end
  end

  @spec key(term()) :: key()
  def key(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @spec fetch_and_store(key(), (-> fetch_result())) :: fetch_result()
  defp fetch_and_store(key, fun) do
    case fun.() do
      {:ok, value} = ok ->
        _ = call({:put, key, value})
        ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec call(term()) :: {:ok, term()} | :unavailable
  defp call(message) do
    if Process.whereis(__MODULE__) do
      try do
        {:ok, GenServer.call(__MODULE__, message)}
      catch
        :exit, _reason -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  @spec init(nil) :: {:ok, state()}
  def init(nil), do: {:ok, %{entries: %{}, sequence: 0}}

  @impl true
  @spec handle_call({:get, key()}, GenServer.from(), state()) ::
          {:reply, {:hit, value()} | :miss, state()}
  def handle_call({:get, key}, _from, state) do
    now = now_ms()
    state = prune_expired(state, now)

    case Map.fetch(state.entries, key) do
      {:ok, %{value: value, expires_at: expires_at}} when expires_at > now ->
        {:reply, {:hit, value}, state}

      _missing_or_expired ->
        {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}
    end
  end

  @impl true
  @spec handle_call({:put, key(), value()}, GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call({:put, key, value}, _from, state) do
    now = now_ms()
    ttl_ms = ttl_ms()

    state =
      if ttl_ms >= 0 do
        state
        |> prune_expired(now)
        |> put_entry(key, value, now, ttl_ms)
        |> enforce_max_entries()
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  @spec handle_call(:clear, GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: %{}}}
  end

  @spec put_entry(state(), key(), value(), integer(), non_neg_integer()) :: state()
  defp put_entry(state, key, value, now, ttl_ms) do
    sequence = state.sequence + 1

    entry = %{
      value: value,
      expires_at: now + ttl_ms,
      inserted_at: sequence
    }

    %{state | entries: Map.put(state.entries, key, entry), sequence: sequence}
  end

  @spec prune_expired(state(), integer()) :: state()
  defp prune_expired(state, now) do
    entries =
      Map.reject(state.entries, fn {_key, %{expires_at: expires_at}} ->
        expires_at <= now
      end)

    %{state | entries: entries}
  end

  @spec enforce_max_entries(state()) :: state()
  defp enforce_max_entries(state) do
    max_entries = max_entries()

    if map_size(state.entries) <= max_entries do
      state
    else
      entries =
        state.entries
        |> Enum.sort_by(fn {_key, %{inserted_at: inserted_at}} -> inserted_at end)
        |> Enum.drop(map_size(state.entries) - max_entries)
        |> Map.new()

      %{state | entries: entries}
    end
  end

  @spec enabled?() :: boolean()
  defp enabled? do
    Application.get_env(:platser, :geocoder_cache_enabled?, true) == true
  end

  @spec ttl_ms() :: integer()
  defp ttl_ms do
    case Application.get_env(:platser, :geocoder_cache_ttl_ms, @default_ttl_ms) do
      value when is_integer(value) -> value
      _invalid -> @default_ttl_ms
    end
  end

  @spec max_entries() :: pos_integer()
  defp max_entries do
    case Application.get_env(:platser, :geocoder_cache_max_entries, @default_max_entries) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_max_entries
    end
  end

  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end
