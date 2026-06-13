defmodule Platser.Events.ManagerAuditEntry do
  @view_manager_audit_roles Platser.Events.MapAccess.roles_for_capability(:view_manager_audit)

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "manager_audit_entries"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_for_event do
      description "List manager-only audit entries for an event."
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
      prepare build(sort: [inserted_at: :desc])
    end

    create :record do
      description "Internal: append a manager audit entry. Call with authorize?: false."

      accept [
        :action,
        :event_id,
        :actor_id,
        :target_user_id,
        :old_value,
        :new_value,
        :message,
        :metadata
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and role in ^@view_manager_audit_roles
                     )
                   )
    end

    policy action_type(:create) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :action, :atom do
      allow_nil? false

      constraints one_of: [
                    :member_removed,
                    :permission_changed,
                    :join_code_regenerated,
                    :join_code_invalidated,
                    :participation_settings_changed,
                    :operator_support_accessed
                  ]
    end

    attribute :target_user_id, :uuid
    attribute :old_value, :string
    attribute :new_value, :string

    attribute :message, :string do
      allow_nil? false
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :actor, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
