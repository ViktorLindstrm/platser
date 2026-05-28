defmodule Platser.Events.Event do
  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Events,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "events"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :description, :starts_at, :ends_at]
      change relate_actor(:creator)
      change Platser.Events.Changes.GenerateJoinCode
      change Platser.Events.Changes.CreateAdminMembership
    end

    read :get_by_join_code do
      description "Look up an event by its invite join code. Any authenticated user may call this."
      get? true
      argument :join_code, :string, allow_nil?: false
      filter expr(join_code == ^arg(:join_code))
    end

    update :regenerate_join_code do
      description "Replaces the event's join code with a freshly generated one."
      require_atomic? false
      change Platser.Events.Changes.GenerateJoinCode
    end
  end

  policies do
    policy action(:create) do
      authorize_if actor_present()
    end

    policy action(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
    end

    policy action(:get_by_join_code) do
      authorize_if actor_present()
    end

    policy action(:regenerate_join_code) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id) and role == :admin))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :description, :string

    attribute :starts_at, :utc_datetime do
      allow_nil? false
    end

    attribute :ends_at, :utc_datetime do
      allow_nil? false
    end

    attribute :join_code, :string do
      allow_nil? false
    end
  end

  relationships do
    belongs_to :creator, Platser.Accounts.User do
      allow_nil? false
    end

    has_many :memberships, Platser.Events.Membership
    has_many :pois, Platser.Map.Poi
    has_many :geofences, Platser.Map.Geofence
    has_many :entries, Platser.Activity.Entry
  end
end
