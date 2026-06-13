defmodule Platser.Events.ManagerAuditPropertyTest do
  use Platser.DataCase, async: false
  use ExUnitProperties

  alias Platser.Accounts.User
  alias Platser.Activity
  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.Membership

  describe "manager audit rows" do
    property "access-management transitions create manager-only audit entries and no public feed entries" do
      check all(
              action <- StreamData.member_of(audited_actions()),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 15
            ) do
        owner = create_user("audit_owner_#{tag}")
        target = create_user("audit_target_#{tag}")
        event = create_event(owner, "Audit #{tag}")
        target_membership = join_event!(event, target)

        {:ok, feed_before} = Activity.list_entries_for_event(event.id, actor: owner)

        assert {:ok, expected} = run_audited_action(action, event, target_membership, owner)

        {:ok, audit_entries} = Events.list_manager_audit_entries(event.id, actor: owner)
        {:ok, feed_after} = Activity.list_entries_for_event(event.id, actor: owner)

        assert Enum.any?(audit_entries, &audit_entry_matches?(&1, expected))
        assert Enum.map(feed_after, & &1.id) == Enum.map(feed_before, & &1.id)
      end
    end

    property "audit visibility is full-manager only and not granted by site-wide superuser" do
      check all(
              role <- StreamData.member_of([:content_manager, :participant]),
              tag <- StreamData.integer(1..1_000_000),
              max_runs: 8
            ) do
        owner = create_user("audit_visibility_owner_#{tag}")
        scoped_member = create_user("audit_visibility_member_#{tag}")
        audit_target = create_user("audit_visibility_target_#{tag}")
        service_admin = create_user("audit_visibility_admin_#{tag}") |> set_superuser!()
        event = create_event(owner, "Audit Visibility #{tag}")
        membership = join_event!(event, scoped_member)
        audit_target_membership = join_event!(event, audit_target)

        assert {:ok, _updated} =
                 Events.update_member_role(membership, %{role: role}, actor: owner)

        assert {:ok, _updated} =
                 Events.update_member_role(
                   audit_target_membership,
                   %{role: :content_manager},
                   actor: owner
                 )

        assert {:ok, entries} = Events.list_manager_audit_entries(event.id, actor: owner)
        assert Enum.any?(entries, &(&1.action == :permission_changed))

        assert {:ok, []} = Events.list_manager_audit_entries(event.id, actor: scoped_member)

        assert {:ok, []} = Events.list_manager_audit_entries(event.id, actor: service_admin)
      end
    end

    property "normal clients cannot append audit entries directly" do
      check all(tag <- StreamData.integer(1..1_000_000), max_runs: 5) do
        owner = create_user("audit_direct_owner_#{tag}")
        event = create_event(owner, "Audit Direct #{tag}")

        assert {:error, %Ash.Error.Forbidden{}} =
                 Events.create_manager_audit_entry(
                   %{
                     action: :member_removed,
                     event_id: event.id,
                     actor_id: owner.id,
                     target_user_id: owner.id,
                     old_value: "participant",
                     message: "Direct write attempt.",
                     metadata: %{}
                   },
                   actor: owner
                 )
      end
    end
  end

  @spec audited_actions() :: [atom()]
  defp audited_actions do
    [
      :member_removed,
      :permission_changed,
      :join_code_regenerated,
      :join_code_invalidated,
      :participation_settings_changed
    ]
  end

  @spec run_audited_action(atom(), Event.t(), Membership.t(), User.t()) ::
          {:ok, map()} | {:error, term()}
  defp run_audited_action(:member_removed, _event, target_membership, owner) do
    case Events.remove_member(target_membership, actor: owner) do
      result when result in [:ok] ->
        {:ok,
         %{
           action: :member_removed,
           target_user_id: target_membership.user_id,
           old_value: "participant",
           new_value: nil
         }}

      error ->
        error
    end
  end

  defp run_audited_action(:permission_changed, _event, target_membership, owner) do
    case Events.update_member_role(target_membership, %{role: :content_manager}, actor: owner) do
      {:ok, updated} ->
        {:ok,
         %{
           action: :permission_changed,
           target_user_id: updated.user_id,
           old_value: "participant",
           new_value: "content_manager"
         }}

      error ->
        error
    end
  end

  defp run_audited_action(:join_code_regenerated, event, _target_membership, owner) do
    case Events.regenerate_event_join_code(event, actor: owner) do
      {:ok, _updated} ->
        {:ok,
         %{
           action: :join_code_regenerated,
           target_user_id: nil,
           old_value: "active",
           new_value: "regenerated"
         }}

      error ->
        error
    end
  end

  defp run_audited_action(:join_code_invalidated, event, _target_membership, owner) do
    case Events.invalidate_event_join_code(event, actor: owner) do
      {:ok, _updated} ->
        {:ok,
         %{
           action: :join_code_invalidated,
           target_user_id: nil,
           old_value: "active",
           new_value: "invalidated"
         }}

      error ->
        error
    end
  end

  defp run_audited_action(:participation_settings_changed, event, _target_membership, owner) do
    attrs = %{allow_participant_comments: !event.allow_participant_comments}

    case Events.update_event_settings(event, attrs, actor: owner) do
      {:ok, _updated} ->
        {:ok,
         %{
           action: :participation_settings_changed,
           target_user_id: nil,
           old_value: nil,
           new_value: nil
         }}

      error ->
        error
    end
  end

  @spec audit_entry_matches?(Platser.Events.ManagerAuditEntry.t(), map()) :: boolean()
  defp audit_entry_matches?(entry, expected) do
    entry.action == expected.action and
      entry.target_user_id == expected.target_user_id and
      entry.old_value == expected.old_value and
      entry.new_value == expected.new_value
  end

  @spec create_user(String.t()) :: User.t()
  defp create_user(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Ash.create(
        User,
        %{
          email: "#{tag}_#{n}@example.com",
          display_name: "User #{tag} #{n}",
          password: "password123",
          password_confirmation: "password123"
        },
        action: :register,
        authorize?: false,
        context: %{strategy_name: :password}
      )

    user
  end

  @spec create_event(User.t(), String.t()) :: Event.t()
  defp create_event(owner, name) do
    {:ok, event} =
      Events.create_event(
        %{
          name: name,
          description: "Private event",
          starts_at: DateTime.utc_now(),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: owner
      )

    event
  end

  @spec join_event!(Event.t(), User.t()) :: Membership.t()
  defp join_event!(event, user) do
    {:ok, membership} = Events.join_event(event.join_code, actor: user)
    membership
  end

  @spec set_superuser!(User.t()) :: User.t()
  defp set_superuser!(user) do
    {:ok, superuser} =
      Ash.update(user, %{superuser: true}, action: :set_superuser, authorize?: false)

    superuser
  end
end
