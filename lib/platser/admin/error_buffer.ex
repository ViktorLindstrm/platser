defmodule Platser.Admin.ErrorBuffer do
  @moduledoc """
  ETS-backed GenServer that captures the last N error-level log entries.

  Acts as both a GenServer (starts/manages the ETS table and Logger handler) and
  the Logger handler module itself (implements `log/2` for the `:logger` behaviour).
  All writes happen directly via ETS from the logger handler callback to avoid
  blocking the logger on any process mailbox.
  """

  use GenServer

  @table :platser_error_buffer
  @handler_id :platser_error_buffer
  @max_entries 200

  @type entry :: %{
          id: integer(),
          level: :error | :critical | :emergency | :alert,
          message: String.t(),
          module: String.t() | nil,
          timestamp: DateTime.t()
        }

  @type group :: %{
          key: String.t(),
          module: String.t() | nil,
          message_prefix: String.t(),
          count: non_neg_integer(),
          last_seen: DateTime.t(),
          sample: String.t()
        }

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns all entries ordered newest first."
  @spec list_entries() :: [entry()]
  def list_entries do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.sort_by(& &1.id, :desc)
    end
  end

  @doc "Returns error entries grouped by module + message prefix, sorted by count desc."
  @spec grouped_errors() :: [group()]
  def grouped_errors do
    list_entries()
    |> Enum.group_by(fn entry ->
      module = entry.module || "unknown"
      prefix = String.slice(entry.message || "", 0, 60)
      {module, prefix}
    end)
    |> Enum.map(fn {{module, prefix}, entries} ->
      latest = Enum.max_by(entries, & &1.id)

      %{
        key: "#{module}:#{prefix}",
        module: module,
        message_prefix: prefix,
        count: length(entries),
        last_seen: latest.timestamp,
        sample: latest.message
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc "Clears all entries from the buffer."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])

    :logger.add_handler(@handler_id, __MODULE__, %{
      level: :error,
      config: %{}
    })

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :logger.remove_handler(@handler_id)
    :ok
  end

  # --- Logger handler callbacks ---

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _handler_config)
      when level in [:error, :critical, :emergency, :alert] do
    if :ets.whereis(@table) != :undefined do
      id = :erlang.unique_integer([:monotonic, :positive])
      module = meta[:module] |> then(fn m -> if m, do: inspect(m), else: nil end)

      entry = %{
        id: id,
        level: level,
        message: format_msg(msg),
        module: module,
        timestamp: DateTime.utc_now()
      }

      :ets.insert(@table, {id, entry})
      trim_oldest()
    end

    :ok
  end

  def log(_event, _config), do: :ok

  # --- Private helpers ---

  @spec trim_oldest() :: :ok
  defp trim_oldest do
    size = :ets.info(@table, :size)

    if size > @max_entries do
      case :ets.first(@table) do
        :"$end_of_table" -> :ok
        first_key -> :ets.delete(@table, first_key)
      end
    end

    :ok
  end

  @spec format_msg(term()) :: String.t()
  defp format_msg({:string, str}), do: IO.chardata_to_string(str)
  defp format_msg({:report, report}), do: inspect(report)

  defp format_msg({fmt, args}) when is_list(args) do
    :io_lib.format(fmt, args) |> IO.chardata_to_string()
  rescue
    _ -> inspect({fmt, args})
  end

  defp format_msg(other), do: inspect(other)
end
