defmodule Platser.Admin.ErrorBufferPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Admin.ErrorBuffer

  @max_entries 200

  setup do
    ErrorBuffer.clear()
    :ok
  end

  @spec inject_n_errors(non_neg_integer()) :: :ok
  defp inject_n_errors(0), do: :ok

  defp inject_n_errors(n) do
    for i <- 1..n//1 do
      ErrorBuffer.log(
        %{level: :error, msg: {:string, "property test entry #{i}"}, meta: %{}},
        %{}
      )
    end

    :ok
  end

  property "buffer size never exceeds #{@max_entries} regardless of insert count" do
    check all(count <- integer(1..300)) do
      ErrorBuffer.clear()
      inject_n_errors(count)
      assert length(ErrorBuffer.list_entries()) <= @max_entries
    end
  end

  property "buffer size equals min(insert_count, #{@max_entries})" do
    check all(count <- integer(1..300)) do
      ErrorBuffer.clear()
      inject_n_errors(count)
      expected = min(count, @max_entries)
      assert length(ErrorBuffer.list_entries()) == expected
    end
  end

  property "grouped_errors count sum equals total entry count" do
    check all(count <- integer(0..50)) do
      ErrorBuffer.clear()
      inject_n_errors(count)

      groups = ErrorBuffer.grouped_errors()
      group_total = Enum.sum(Enum.map(groups, & &1.count))
      entries_total = length(ErrorBuffer.list_entries())

      assert group_total == entries_total
    end
  end

  property "grouped_errors is deterministic for the same entries" do
    check all(count <- integer(1..20)) do
      ErrorBuffer.clear()
      inject_n_errors(count)

      groups_1 = ErrorBuffer.grouped_errors()
      groups_2 = ErrorBuffer.grouped_errors()

      assert groups_1 == groups_2
    end
  end

  property "all group keys are non-empty strings" do
    check all(count <- integer(1..30)) do
      ErrorBuffer.clear()
      inject_n_errors(count)

      for group <- ErrorBuffer.grouped_errors() do
        assert is_binary(group.key)
        assert byte_size(group.key) > 0
      end
    end
  end

  property "entries retain correct level after mixed-level inserts" do
    check all(count <- integer(1..50)) do
      ErrorBuffer.clear()

      for i <- 1..count do
        level = Enum.random([:error, :critical])

        ErrorBuffer.log(
          %{level: level, msg: {:string, "entry #{i}"}, meta: %{}},
          %{}
        )
      end

      for entry <- ErrorBuffer.list_entries() do
        assert entry.level in [:error, :critical]
      end
    end
  end
end
