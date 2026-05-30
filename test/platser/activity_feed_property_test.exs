defmodule Platser.ActivityFeedPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Activity

  @moduledoc """
  StreamData property tests for the Activity feed domain.
  """

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # ── Generators ──────────────────────────────────────────────────────────────

  @valid_actions [
    :poi_published,
    :geofence_published,
    :joined_event,
    :comment_added,
    :entered_geofence,
    :exited_geofence,
    :checked_in
  ]

  defp valid_action_gen do
    StreamData.member_of(@valid_actions)
  end

  defp invalid_action_gen do
    StreamData.filter(StreamData.atom(:alphanumeric), fn a ->
      a not in @valid_actions
    end)
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "activity_test_#{n}@example.com",
          display_name: "Feed User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event_with_member do
    user = create_user()

    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Feed Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: user
      )

    {user, event}
  end

  defp insert_entry(user, event, action \\ :poi_published, subject_id \\ Ecto.UUID.generate()) do
    n = System.unique_integer([:positive])

    Activity.create_entry(
      %{
        action: action,
        subject_type: "poi",
        subject_id: subject_id,
        message: "Test entry #{n}",
        event_id: event.id
      },
      actor: user,
      authorize?: false
    )
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "ordering invariant" do
    property "inserting N entries always returns exactly N entries newest-first" do
      check all(
              n <- StreamData.integer(1..20),
              max_runs: 20
            ) do
        {user, event} = create_event_with_member()

        Enum.each(1..n, fn _ ->
          {:ok, _} = insert_entry(user, event)
        end)

        {:ok, fetched} = Activity.list_entries_for_event(event.id, actor: user)

        assert length(fetched) == n

        pairs = Enum.zip(fetched, tl(fetched))

        assert Enum.all?(pairs, fn {newer, older} ->
                 DateTime.compare(newer.inserted_at, older.inserted_at) in [:gt, :eq]
               end),
               "Entries not in newest-first order: #{inspect(Enum.map(fetched, & &1.inserted_at))}"
      end
    end
  end

  describe "subject filtering" do
    property "list_entries_for_subject returns only entries for the requested subject" do
      check all(
              subject_entry_count <- StreamData.integer(1..8),
              other_entry_count <- StreamData.integer(1..8),
              max_runs: 20
            ) do
        {user, event} = create_event_with_member()
        subject_id = Ecto.UUID.generate()

        Enum.each(1..subject_entry_count, fn _ ->
          {:ok, _} = insert_entry(user, event, :poi_published, subject_id)
        end)

        Enum.each(1..other_entry_count, fn _ ->
          {:ok, _} = insert_entry(user, event, :comment_added, Ecto.UUID.generate())
        end)

        {:ok, fetched} = Activity.list_entries_for_subject(subject_id, actor: user)

        assert length(fetched) == subject_entry_count
        assert Enum.all?(fetched, &(&1.subject_id == subject_id))
      end
    end
  end

  describe "activity filtering" do
    property "checked-in filter only returns checked-in entries" do
      check all(
              checked_in_count <- StreamData.integer(1..8),
              other_count <- StreamData.integer(1..8),
              max_runs: 20
            ) do
        {user, event} = create_event_with_member()

        Enum.each(1..checked_in_count, fn _ ->
          {:ok, _} = insert_entry(user, event, :checked_in)
        end)

        Enum.each(1..other_count, fn _ ->
          {:ok, _} = insert_entry(user, event, :poi_published)
        end)

        {:ok, fetched} = Activity.list_entries_for_event_with_filter(event.id, user, :check_ins)

        assert fetched != []
        assert Enum.all?(fetched, &(&1.action == :checked_in))
      end
    end
  end

  describe "unread badge count" do
    property "count_unread_since equals entries inserted after last_read_at boundary" do
      check all(
              before_count <- StreamData.integer(0..10),
              after_count <- StreamData.integer(1..10),
              base_offset <- StreamData.integer(0..100_000),
              max_runs: 100
            ) do
        base = DateTime.add(~U[2025-01-01 00:00:00Z], base_offset, :second)

        before_entries =
          for i <- 0..max(before_count - 1, 0), before_count > 0 do
            %{inserted_at: DateTime.add(base, i, :second)}
          end

        last_read_at = DateTime.add(base, before_count, :second)

        after_entries =
          for i <- 1..after_count do
            %{inserted_at: DateTime.add(last_read_at, i, :second)}
          end

        all_entries = Enum.shuffle(after_entries ++ before_entries)

        unread = Activity.count_unread_since(all_entries, last_read_at)

        assert unread == after_count,
               "Expected #{after_count} unread; got #{unread}; last_read_at=#{last_read_at}"
      end
    end
  end

  describe "action enum validation" do
    property "any valid action enum value is accepted" do
      check all(action <- valid_action_gen(), max_runs: length(@valid_actions)) do
        {user, event} = create_event_with_member()

        result =
          Activity.create_entry(
            %{
              action: action,
              subject_type: "poi",
              subject_id: Ecto.UUID.generate(),
              message: "Valid action: #{action}",
              event_id: event.id
            },
            actor: user,
            authorize?: false
          )

        assert {:ok, entry} = result
        assert entry.action == action
      end
    end

    property "values outside the action enum are rejected" do
      check all(action <- invalid_action_gen(), max_runs: 20) do
        {user, event} = create_event_with_member()

        result =
          Activity.create_entry(
            %{
              action: action,
              subject_type: "poi",
              subject_id: Ecto.UUID.generate(),
              message: "Invalid action: #{action}",
              event_id: event.id
            },
            actor: user,
            authorize?: false
          )

        assert {:error, _} = result
      end
    end
  end

  describe "concurrent inserts" do
    property "concurrent inserts via Task.async_stream produce no duplicates or lost writes" do
      check all(n <- StreamData.integer(2..8), max_runs: 10) do
        {user, event} = create_event_with_member()
        event_id = event.id

        pid = self()

        results =
          1..n
          |> Task.async_stream(
            fn _ ->
              Ecto.Adapters.SQL.Sandbox.allow(Platser.Repo, pid, self())
              insert_entry(user, %{id: event_id}, :poi_published)
            end,
            timeout: 10_000
          )
          |> Enum.to_list()

        assert Enum.all?(results, fn {:ok, result} -> match?({:ok, _}, result) end),
               "Some concurrent inserts failed: #{inspect(results)}"

        {:ok, fetched} = Activity.list_entries_for_event(event_id, actor: user)

        assert length(fetched) == n, "Expected #{n} entries, got #{length(fetched)}"

        fetched_ids = Enum.map(fetched, & &1.id)
        unique_ids = Enum.uniq(fetched_ids)

        assert length(unique_ids) == length(fetched_ids),
               "Duplicate entry IDs found: #{inspect(fetched_ids)}"
      end
    end
  end
end
