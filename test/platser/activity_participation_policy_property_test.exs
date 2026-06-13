defmodule Platser.ActivityParticipationPolicyPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Platser.Accounts
  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.Activity.Entry
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.MapAccess

  describe "participation setting policies" do
    property "comment and check-in writes follow map role and participant settings" do
      check all(
              role <- StreamData.member_of(MapAccess.roles()),
              comments_enabled? <- StreamData.boolean(),
              check_ins_enabled? <- StreamData.boolean(),
              action <- StreamData.member_of([:comment_added, :checked_in]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 24
            ) do
        owner = create_user("policy_owner_#{tag}")
        actor = create_user("policy_actor_#{tag}")
        event = create_event(owner, "Participation #{tag}")
        insert_membership!(event, actor, role)

        event =
          update_settings!(event, owner, %{
            allow_participant_comments: comments_enabled?,
            allow_participant_check_ins: check_ins_enabled?
          })

        result = create_participation_entry(action, event, actor)

        expected? =
          MapAccess.manager?(role) or
            (action == :comment_added and comments_enabled?) or
            (action == :checked_in and check_ins_enabled?)

        if expected? do
          assert {:ok, %Entry{}} = result
        else
          assert {:error, %Ash.Error.Forbidden{}} = result
          assert_no_entries(event, actor, action)
        end
      end
    end

    property "guest participants follow restricted participation settings" do
      check all(
              comments_enabled? <- StreamData.boolean(),
              check_ins_enabled? <- StreamData.boolean(),
              action <- StreamData.member_of([:comment_added, :checked_in]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 12
            ) do
        owner = create_user("guest_policy_owner_#{tag}")
        guest = create_guest_user("Guest Policy #{tag}")
        event = create_event(owner, "Guest Participation #{tag}")
        {:ok, _membership} = Events.join_event(event.join_code, actor: guest)

        event =
          update_settings!(event, owner, %{
            allow_participant_comments: comments_enabled?,
            allow_participant_check_ins: check_ins_enabled?
          })

        result = create_participation_entry(action, event, guest)

        expected? =
          (action == :comment_added and comments_enabled?) or
            (action == :checked_in and check_ins_enabled?)

        if expected? do
          assert {:ok, %Entry{}} = result
        else
          assert {:error, %Ash.Error.Forbidden{}} = result
          assert_no_entries(event, guest, action)
        end
      end
    end

    property "site-wide superuser alone cannot create participation entries" do
      check all(action <- StreamData.member_of([:comment_added, :checked_in]), max_runs: 2) do
        owner = create_user("superuser_policy_owner")
        service_admin = create_user("service_admin_policy") |> set_superuser!()
        event = create_event(owner, "Superuser Participation")

        result = create_participation_entry(action, event, service_admin)

        assert {:error, %Ash.Error.Forbidden{}} = result
        assert_no_entries(event, service_admin, action)
      end
    end
  end

  @spec create_participation_entry(:comment_added | :checked_in, Event.t(), User.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  defp create_participation_entry(:comment_added, event, actor) do
    Activity.create_entry(
      %{
        action: :comment_added,
        subject_type: "poi",
        subject_id: Ecto.UUID.generate(),
        message: "#{actor.display_name} commented: Hello",
        event_id: event.id
      },
      actor: actor
    )
  end

  defp create_participation_entry(:checked_in, event, actor) do
    Activity.create_check_in(
      %{
        event_id: event.id,
        lat: 59.33,
        lng: 18.06,
        message: "#{actor.display_name} checked in"
      },
      actor: actor
    )
  end

  @spec assert_no_entries(Event.t(), User.t(), :comment_added | :checked_in) :: true
  defp assert_no_entries(event, actor, action) do
    {:ok, entries} =
      Entry
      |> Ash.Query.for_read(:list_by_event, %{event_id: event.id})
      |> Ash.Query.filter(action == ^action and actor_id == ^actor.id)
      |> Ash.read(actor: actor)

    assert entries == []
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "Participation User #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_guest_user(String.t()) :: User.t()
  defp create_guest_user(display_name) do
    {:ok, guest} = Accounts.create_guest_user(display_name, authorize?: false)
    guest
  end

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(owner, name) do
    {:ok, event} =
      Events.create_event(
        %{
          name: name,
          description: "Participation policy event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
  end

  @spec update_settings!(Event.t(), User.t(), map()) :: Event.t()
  defp update_settings!(event, actor, attrs) do
    {:ok, updated} = Events.update_event_settings(event, attrs, actor: actor)
    updated
  end

  @spec insert_membership!(Event.t(), User.t(), MapAccess.role()) :: :ok
  defp insert_membership!(event, user, role) do
    event_uuid = Ecto.UUID.dump!(event.id)
    user_uuid = Ecto.UUID.dump!(user.id)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Platser.Repo,
        """
        INSERT INTO memberships (id, event_id, user_id, role, joined_at)
        VALUES (gen_random_uuid(), $1, $2, $3, now())
        """,
        [event_uuid, user_uuid, Atom.to_string(role)]
      )

    :ok
  end

  @spec set_superuser!(User.t()) :: User.t()
  defp set_superuser!(user) do
    {:ok, superuser} =
      Ash.update(user, %{superuser: true}, action: :set_superuser, authorize?: false)

    superuser
  end
end
