defmodule PlatserWeb.JoinRateLimiter do
  @moduledoc """
  Fixed-window throttle for public invite-code entry points.
  """

  use GenServer

  @type code :: String.t()
  @type ip_address :: :inet.ip_address()
  @type throttle_key :: {ip_address(), code()}
  @type allow_result :: :allow | :throttle
  @type window_ms :: pos_integer()
  @type limit :: pos_integer()
  @type clock_ms :: integer()
  @type state :: {clock_ms(), pos_integer()}

  @table __MODULE__
  @default_limit 5
  @default_window_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, :ets.tid()}
  def init(_opts) do
    table =
      :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])

    {:ok, table}
  end

  @spec allow?(ip_address(), code()) :: allow_result()
  def allow?(remote_ip, code) do
    allow?(remote_ip, code, now_ms(), limit(), window_ms())
  end

  @spec normalize_code(String.t()) :: String.t()
  def normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  @spec reset_all() :: :ok
  def reset_all do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec allow?(ip_address(), code(), clock_ms(), limit(), window_ms()) :: allow_result()
  def allow?(remote_ip, code, now, limit, window_ms)
      when is_tuple(remote_ip) and is_binary(code) and is_integer(now) and is_integer(limit) and
             limit > 0 and is_integer(window_ms) and window_ms > 0 do
    table = ensure_table!()
    key = {remote_ip, normalize_code(code)}

    case :ets.lookup(table, key) do
      [] ->
        :ets.insert(table, {key, {now, 1}})
        :allow

      [{^key, {started_at, _count}}] when now - started_at >= window_ms ->
        :ets.insert(table, {key, {now, 1}})
        :allow

      [{^key, {started_at, count}}] when count < limit ->
        :ets.insert(table, {key, {started_at, count + 1}})
        :allow

      [{^key, {_started_at, _count}}] ->
        :throttle
    end
  end

  @spec ensure_table!() :: :ets.tid() | atom()
  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError ->
      @table
  end

  @spec now_ms() :: clock_ms()
  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  @spec limit() :: limit()
  defp limit do
    Application.get_env(:platser, __MODULE__, [])
    |> Keyword.get(:limit, @default_limit)
  end

  @spec window_ms() :: window_ms()
  defp window_ms do
    Application.get_env(:platser, __MODULE__, [])
    |> Keyword.get(:window_ms, @default_window_ms)
  end
end
