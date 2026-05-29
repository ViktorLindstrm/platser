defmodule Platser.Map.Poi do
  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Map,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "pois"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_by_event do
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
    end

    create :create do
      primary? true
      accept [:name, :description, :category, :location, :event_id]
      change set_attribute(:visibility, :private)
      change relate_actor(:creator)
    end

    update :publish do
      accept []
      require_atomic? false

      validate attribute_equals(:visibility, :private) do
        message "POI is already published"
      end

      change set_attribute(:visibility, :public)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
      end

      change Platser.Map.Changes.BroadcastPublish
    end

    update :update do
      accept [:name, :description, :category, :location]
      require_atomic? false

      validate attribute_equals(:visibility, :private) do
        message "can only edit draft POIs"
      end
    end

    destroy :destroy do
      primary? true
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

    policy action_type(:create) do
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id)))
    end

    policy action(:update) do
      authorize_if expr(creator_id == ^actor(:id))
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id) and role == :admin))
    end

    policy action(:publish) do
      authorize_if expr(creator_id == ^actor(:id))
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id) and role == :admin))
    end

    policy action_type(:destroy) do
      authorize_if expr(creator_id == ^actor(:id))
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id) and role == :admin))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :description, :string

    attribute :category, :atom do
      allow_nil? false
      constraints one_of: [:viewpoint, :camp, :hazard, :meeting_point, :food, :other]
    end

    attribute :location, Platser.Types.Geometry do
      allow_nil? false
    end

    attribute :visibility, :atom do
      allow_nil? false
      constraints one_of: [:public, :private]
    end

    attribute :published_at, :utc_datetime
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :creator, Platser.Accounts.User do
      allow_nil? false
    end

    has_many :attachments, Platser.Media.Attachment
  end
end
