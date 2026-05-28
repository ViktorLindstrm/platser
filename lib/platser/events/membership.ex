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
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     user_id == ^actor(:id) or
                       exists(event.memberships, user_id == ^actor(:id) and role == :admin)
                   )
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
