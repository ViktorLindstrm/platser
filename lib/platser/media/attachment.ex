defmodule Platser.Media.Attachment do
  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Media,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "media_attachments"
    repo(Platser.Repo)

    references do
      reference(:poi, on_delete: :delete)
    end
  end

  actions do
    defaults [:read]

    read :list_by_poi do
      argument :poi_id, :uuid, allow_nil?: false
      filter expr(poi_id == ^arg(:poi_id))
    end

    create :create do
      accept [:filename, :stored_filename, :content_type, :path, :poi_id]
      change relate_actor(:uploader)
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(poi.event.memberships, user_id == ^actor(:id)))
    end

    policy action_type(:create) do
      authorize_if expr(poi.creator_id == ^actor(:id))
    end

    policy action_type(:destroy) do
      authorize_if expr(uploader_id == ^actor(:id))
      authorize_if expr(exists(poi.event.memberships, user_id == ^actor(:id) and role == :admin))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :filename, :string do
      allow_nil? false
      description "Original client-supplied filename"
    end

    attribute :stored_filename, :string do
      allow_nil? false
      description "Server-generated unique filename (UUID prefix)"
    end

    attribute :content_type, :string do
      allow_nil? false
    end

    attribute :path, :string do
      allow_nil? false
      description "URL path, e.g. /uploads/{poi_id}/{stored_filename}"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :poi, Platser.Map.Poi do
      allow_nil? false
    end

    belongs_to :uploader, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
