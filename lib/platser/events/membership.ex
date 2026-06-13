defmodule Platser.Events.Membership do
  @manage_members_roles Platser.Events.MapAccess.roles_for_capability(:manage_members)

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_for_event do
      description "List all memberships for an event. Requires actor to be an event member."
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
      prepare build(sort: [joined_at: :asc], load: [:user])
    end

    create :join do
      description "Join an event via its invite join code."
      argument :join_code, :string, allow_nil?: false, sensitive?: true
      change set_attribute(:role, :participant)
      change relate_actor(:user)
      change Platser.Events.Changes.SetEventByJoinCode
      change Platser.Events.Changes.BroadcastJoin
    end

    create :create_admin do
      description "Internal: create a full manager membership for the event creator. Call with authorize?: false."
      accept []
      argument :event_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:role, :full_manager)

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :event_id,
          Ash.Changeset.get_argument(changeset, :event_id)
        )
        |> Ash.Changeset.force_change_attribute(
          :user_id,
          Ash.Changeset.get_argument(changeset, :user_id)
        )
      end
    end

    destroy :remove do
      description "Remove a member from an event. Only full managers can remove members, and the last full manager cannot be removed."
      require_atomic? false
      change Platser.Events.Changes.GuardLastAdmin
    end

    update :update_role do
      description "Update a member's role. Only full managers can update roles, and the last full manager cannot be demoted."
      accept [:role]
      require_atomic? false
      change Platser.Events.Changes.GuardLastAdmin
    end
  end

  policies do
    policy action(:read) do
      authorize_if expr(
                     user_id == ^actor(:id) or
                       exists(
                         event.memberships,
                         user_id == ^actor(:id) and role in ^@manage_members_roles
                       )
                   )
    end

    policy action(:list_for_event) do
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id)))
    end

    policy action(:join) do
      authorize_if actor_present()
    end

    policy action(:remove) do
      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and role in ^@manage_members_roles
                     )
                   )
    end

    policy action(:update_role) do
      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and role in ^@manage_members_roles
                     )
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: Platser.Events.MapAccess.compatible_roles()
    end

    create_timestamp :joined_at
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :user, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
