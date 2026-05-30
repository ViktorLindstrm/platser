defmodule Platser.EventsJoinActivityPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Activity
  alias Platser.Events

  @moduledoc """
  StreamData property tests verifying that joining an event always produces
  a :joined_event Activity.Entry with the correct fields.
  """

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "join_activity_#{n}@example.com",
          display_name: "Join User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event_with_admin do
    admin = create_user()

    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: "Join Activity Test Event",
          description: "desc",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: admin
      )

    {admin, event}
  end

  defp joined_event_entries_for(event_id, actor) do
    {:ok, entries} = Activity.list_entries_for_event(event_id, actor: actor)
    Enum.filter(entries, &(&1.action == :joined_event))
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "joined_event activity entry on join" do
    property "joining an event always creates exactly one :joined_event entry for the joining user" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {admin, event} = create_event_with_admin()
        joiner = create_user()

        assert {:ok, _membership} = Events.join_event(event.join_code, actor: joiner)

        entries = joined_event_entries_for(event.id, admin)

        assert length(entries) == 1,
               "Expected 1 :joined_event entry, got #{length(entries)}"
      end
    end

    property "the :joined_event entry has subject_type 'user' and subject_id equal to joining user id" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {admin, event} = create_event_with_admin()
        joiner = create_user()

        assert {:ok, _membership} = Events.join_event(event.join_code, actor: joiner)

        entries = joined_event_entries_for(event.id, admin)
        [entry] = entries

        assert entry.subject_type == "user",
               "Expected subject_type 'user', got '#{entry.subject_type}'"

        assert entry.subject_id == joiner.id,
               "Expected subject_id #{joiner.id}, got #{entry.subject_id}"
      end
    end

    property "attempting to join an already-joined event does not create additional :joined_event entries" do
      check all(_ <- StreamData.constant(:ok), max_runs: 20) do
        {admin, event} = create_event_with_admin()
        joiner = create_user()

        assert {:ok, _membership} = Events.join_event(event.join_code, actor: joiner)

        entries_after_first_join = joined_event_entries_for(event.id, admin)
        assert length(entries_after_first_join) == 1

        assert {:error, _} = Events.join_event(event.join_code, actor: joiner)

        entries_after_second_attempt = joined_event_entries_for(event.id, admin)

        assert length(entries_after_second_attempt) == 1,
               "Expected still 1 :joined_event entry after failed join attempt, got #{length(entries_after_second_attempt)}"
      end
    end

    property "the event admin's initial membership does not produce a :joined_event entry" do
      check all(_ <- StreamData.constant(:ok), max_runs: 10) do
        {admin, event} = create_event_with_admin()

        entries = joined_event_entries_for(event.id, admin)

        assert entries == [],
               "Expected no :joined_event entries for admin membership, got #{length(entries)}"
      end
    end
  end
end
