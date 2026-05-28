defmodule Platser.Events.Membership do
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

    create :join do
      description "Join an event via its invite join code."
      argument :join_code, :string, allow_nil?: false
      change set_attribute(:role, :member)
      change relate_actor(:user)
      change Platser.Events.Changes.SetEventByJoinCode
    end

    create :create_admin do
      description "Internal: create an admin membership for the event creator. Call with authorize?: false."
      accept []
      argument :event_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:role, :admin)

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
  end

  policies do
    policy action(:read) do
      authorize_if expr(
                     user_id == ^actor(:id) or
                       exists(event.memberships, user_id == ^actor(:id) and role == :admin)
                   )
    end

    policy action(:join) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:admin, :member]
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
