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
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
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
