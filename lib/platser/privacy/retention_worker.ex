defmodule Platser.Privacy.RetentionWorker do
  @moduledoc false

  use GenServer

  alias Platser.Privacy.Retention

  @default_initial_delay_ms :timer.minutes(5)
  @default_interval_ms :timer.hours(24)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    initial_delay_ms = Keyword.get(opts, :initial_delay_ms, configured(:initial_delay_ms))
    interval_ms = Keyword.get(opts, :interval_ms, configured(:interval_ms))

    state = %{initial_delay_ms: initial_delay_ms, interval_ms: interval_ms}
    schedule(initial_delay_ms)
    {:ok, state}
  end

  @impl GenServer
  @spec handle_info(:run, map()) :: {:noreply, map()}
  def handle_info(:run, state) do
    _ = Retention.run()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @spec configured(:initial_delay_ms | :interval_ms) :: pos_integer()
  defp configured(:initial_delay_ms) do
    Application.get_env(:platser, :retention_initial_delay_ms, @default_initial_delay_ms)
  end

  defp configured(:interval_ms) do
    Application.get_env(:platser, :retention_interval_ms, @default_interval_ms)
  end

  @spec schedule(pos_integer()) :: reference()
  defp schedule(delay_ms), do: Process.send_after(self(), :run, delay_ms)
end
