defmodule Platser.Map.Geofence do
  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Map,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "geofences"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_by_event do
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(
                     exists(event.memberships, user_id == ^actor(:id)) and
                       (visibility == :public or creator_id == ^actor(:id) or
                          exists(event.memberships, user_id == ^actor(:id) and role == :admin))
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :purpose, :atom do
      allow_nil? false
      constraints one_of: [:boundary, :meeting_zone, :restricted, :camp_area, :other]
    end

    attribute :geometry, Platser.Types.Geometry do
      allow_nil? false
    end

    attribute :visibility, :atom do
      allow_nil? false
      constraints one_of: [:public, :private]
    end

    attribute :color, :string do
      allow_nil? false
    end
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :creator, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
