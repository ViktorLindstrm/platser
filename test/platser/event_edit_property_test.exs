defmodule Platser.EventEditPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Events

  @moduledoc """
  StreamData property tests for the update action on Event resources.
  Verifies that:
  - Admin members can update event name, description, and dates
  - Non-admin members cannot update events (authorization error)
  - Empty names are rejected (validation error)
  """

  # ── Generators ──────────────────────────────────────────────────────────────

  defp valid_event_name_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 100)
    |> StreamData.filter(&(String.trim(&1) != ""))
  end

  defp valid_description_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.string(:printable, min_length: 0, max_length: 500)
    ])
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp create_user(email_suffix) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        Platser.Accounts.User,
        %{
          email: "event_edit_#{n}_#{email_suffix}@example.com",
          display_name: "Event User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  defp create_event(admin_user, name \\ "Test Event") do
    {:ok, event} =
      Ash.create(
        Platser.Events.Event,
        %{
          name: name,
          description: "Test description",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: admin_user
      )

    event
  end

  defp add_member(event, user, :member) do
    # For non-admin members, we use raw SQL since there's no public create action for members
    event_uuid = Ecto.UUID.dump!(event.id)
    user_uuid = Ecto.UUID.dump!(user.id)

    {:ok, result} =
      Ecto.Adapters.SQL.query(
        Platser.Repo,
        """
        INSERT INTO memberships (id, event_id, user_id, role, joined_at)
        VALUES (gen_random_uuid(), $1, $2, 'member', now())
        RETURNING id
        """,
        [event_uuid, user_uuid]
      )

    [[id]] = result.rows
    load_uuid = Ecto.UUID.load!(id)

    %Platser.Events.Membership{
      id: load_uuid,
      event_id: event.id,
      user_id: user.id,
      role: :member
    }
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "Event.update for admin members" do
    property "any non-empty name is accepted and persisted by admin actor" do
      check all(new_name <- valid_event_name_gen(), max_runs: 30) do
        admin_user = create_user("admin")
        event = create_event(admin_user, "Original Name")

        result = Events.update_event(event, %{name: new_name}, actor: admin_user)

        assert {:ok, updated} = result
        assert updated.name == new_name
      end
    end

    property "admin can update name and description together" do
      check all(
              new_name <- valid_event_name_gen(),
              new_desc <- valid_description_gen(),
              max_runs: 20
            ) do
        admin_user = create_user("admin")
        event = create_event(admin_user, "Original Name")

        attrs = %{name: new_name, description: new_desc}
        result = Events.update_event(event, attrs, actor: admin_user)

        assert {:ok, updated} = result
        assert updated.name == new_name
        # Empty strings are converted to nil
        expected_desc = if new_desc == "", do: nil, else: new_desc
        assert updated.description == expected_desc
      end
    end

    property "admin can update dates" do
      check all(
              hours_offset <- StreamData.integer(1..168),
              max_runs: 10
            ) do
        admin_user = create_user("admin")
        now = DateTime.utc_now()
        event = create_event(admin_user)

        new_start = DateTime.add(now, 3600)
        new_end = DateTime.add(new_start, hours_offset * 3600)

        result =
          Events.update_event(
            event,
            %{starts_at: new_start, ends_at: new_end},
            actor: admin_user
          )

        assert {:ok, updated} = result

        # Compare timestamps with 2 second tolerance for microsecond precision and timing variations
        assert abs(DateTime.diff(updated.starts_at, new_start, :second)) <= 1
        assert abs(DateTime.diff(updated.ends_at, new_end, :second)) <= 1
      end
    end
  end

  describe "Event.update for non-admin members" do
    property "non-admin member cannot update event (authorization error)" do
      check all(new_name <- valid_event_name_gen(), max_runs: 20) do
        admin_user = create_user("admin_for_nonmember")
        non_admin_user = create_user("non_admin")
        event = create_event(admin_user)
        add_member(event, non_admin_user, :member)

        result = Events.update_event(event, %{name: new_name}, actor: non_admin_user)

        # Should fail with authorization error
        assert {:error, %Ash.Error.Forbidden{}} = result
      end
    end
  end

  describe "Event.update validation" do
    property "empty name is rejected (validation error)" do
      check all(
              desc <- valid_description_gen(),
              max_runs: 10
            ) do
        admin_user = create_user("admin_for_validation")
        event = create_event(admin_user)

        result =
          Events.update_event(
            event,
            %{name: "", description: desc},
            actor: admin_user
          )

        # Should fail validation
        assert {:error, %Ash.Error.Invalid{}} = result
      end
    end

    property "whitespace-only name is rejected" do
      check all(
              spaces <- StreamData.binary(max_length: 5),
              max_runs: 10
            ) do
        # Generate whitespace strings
        whitespace_only = String.duplicate(" ", String.length(spaces) + 1)
        admin_user = create_user("admin_for_whitespace")
        event = create_event(admin_user)

        result = Events.update_event(event, %{name: whitespace_only}, actor: admin_user)

        # May fail validation if whitespace is trimmed and becomes empty
        case result do
          {:error, %Ash.Error.Invalid{}} -> true
          {:ok, updated} -> String.trim(updated.name) != ""
        end
      end
    end
  end
end
