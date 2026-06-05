defmodule Platser.Admin.ErrorBufferTest do
  use Platser.DataCase, async: false

  alias Platser.Admin.ErrorBuffer

  setup do
    ErrorBuffer.clear()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec inject_error(String.t(), module() | nil) :: :ok
  defp inject_error(message, mod \\ nil) do
    meta = if mod, do: %{module: mod}, else: %{}

    ErrorBuffer.log(
      %{level: :error, msg: {:string, message}, meta: meta},
      %{}
    )
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  describe "list_entries/0" do
    test "returns empty list when no errors have been logged" do
      assert ErrorBuffer.list_entries() == []
    end

    test "returns entries after errors are injected" do
      inject_error("first error")
      inject_error("second error")

      entries = ErrorBuffer.list_entries()
      assert length(entries) == 2
    end

    test "returns entries ordered newest first" do
      inject_error("old error")
      inject_error("new error")

      [first | _] = ErrorBuffer.list_entries()
      assert first.message == "new error"
    end

    test "stores all expected fields" do
      inject_error("test message", ErrorBufferTest)

      [entry] = ErrorBuffer.list_entries()
      assert is_integer(entry.id)
      assert entry.level == :error
      assert entry.message == "test message"
      assert is_binary(entry.module)
      assert %DateTime{} = entry.timestamp
    end
  end

  describe "clear/0" do
    test "removes all entries from the buffer" do
      inject_error("first")
      inject_error("second")
      inject_error("third")

      assert length(ErrorBuffer.list_entries()) == 3

      ErrorBuffer.clear()

      assert ErrorBuffer.list_entries() == []
    end

    test "is idempotent on empty buffer" do
      ErrorBuffer.clear()
      ErrorBuffer.clear()
      assert ErrorBuffer.list_entries() == []
    end
  end

  describe "grouped_errors/0" do
    test "returns empty list when no errors logged" do
      assert ErrorBuffer.grouped_errors() == []
    end

    test "groups entries with the same module and message prefix" do
      # Both messages start with the same 60 characters so they share a group key
      prefix = String.duplicate("x", 60)
      inject_error(prefix <> " detail_a", MyApp.Client)
      inject_error(prefix <> " detail_b", MyApp.Client)

      groups = ErrorBuffer.grouped_errors()
      assert length(groups) == 1
      [group] = groups
      assert group.count == 2
      assert group.module == inspect(MyApp.Client)
    end

    test "separates entries with different modules into different groups" do
      inject_error("timeout", ModuleA)
      inject_error("timeout", ModuleB)

      groups = ErrorBuffer.grouped_errors()
      assert length(groups) == 2
    end

    test "sorts groups by count descending" do
      inject_error("frequent error", FreqMod)
      inject_error("frequent error", FreqMod)
      inject_error("rare error", RareMod)

      [first | _] = ErrorBuffer.grouped_errors()
      assert first.count == 2
      assert first.module == inspect(FreqMod)
    end

    test "each group contains required fields" do
      inject_error("db connection failed", MyApp.Repo)

      [group] = ErrorBuffer.grouped_errors()
      assert is_binary(group.key)
      assert is_binary(group.module)
      assert is_binary(group.message_prefix)
      assert group.count == 1
      assert %DateTime{} = group.last_seen
      assert is_binary(group.sample)
    end
  end

  describe "buffer cap" do
    test "buffer never exceeds 200 entries" do
      for i <- 1..250 do
        inject_error("overflow entry #{i}")
      end

      assert length(ErrorBuffer.list_entries()) <= 200
    end

    test "oldest entries are evicted first when cap is exceeded" do
      for i <- 1..210 do
        inject_error("entry #{i}")
      end

      messages = ErrorBuffer.list_entries() |> Enum.map(& &1.message)
      refute "entry 1" in messages
      assert "entry 210" in messages
    end
  end

  describe "log/2 callback" do
    test "ignores non-error levels" do
      ErrorBuffer.log(%{level: :warning, msg: {:string, "a warning"}, meta: %{}}, %{})
      ErrorBuffer.log(%{level: :info, msg: {:string, "just info"}, meta: %{}}, %{})
      ErrorBuffer.log(%{level: :debug, msg: {:string, "debug msg"}, meta: %{}}, %{})

      assert ErrorBuffer.list_entries() == []
    end

    test "captures :critical level entries" do
      ErrorBuffer.log(%{level: :critical, msg: {:string, "critical failure"}, meta: %{}}, %{})
      assert length(ErrorBuffer.list_entries()) == 1
    end
  end
end
