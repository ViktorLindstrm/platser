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
      reference(:geofence, on_delete: :delete)
    end
  end

  actions do
    defaults [:read]

    read :list_by_poi do
      argument :poi_id, :uuid, allow_nil?: false
      filter expr(poi_id == ^arg(:poi_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :list_by_geofence do
      argument :geofence_id, :uuid, allow_nil?: false
      filter expr(geofence_id == ^arg(:geofence_id))
      prepare build(sort: [inserted_at: :asc])
    end

    create :create do
      accept [:filename, :stored_filename, :content_type, :path, :poi_id]
      change relate_actor(:uploader)

      validate fn changeset, _ ->
        poi_id = Ash.Changeset.get_attribute(changeset, :poi_id)
        geofence_id = Ash.Changeset.get_attribute(changeset, :geofence_id)

        case {poi_id, geofence_id} do
          {nil, nil} ->
            {:error, field: :poi_id, message: "must specify poi_id or geofence_id"}

          {_, nil} ->
            :ok

          {nil, _} ->
            {:error,
             field: :poi_id, message: "use create_for_geofence action for geofence attachments"}

          _ ->
            {:error, field: :poi_id, message: "cannot set both poi_id and geofence_id"}
        end
      end
    end

    create :create_for_geofence do
      accept [:filename, :stored_filename, :content_type, :path, :geofence_id]
      change relate_actor(:uploader)

      validate fn changeset, _ ->
        poi_id = Ash.Changeset.get_attribute(changeset, :poi_id)
        geofence_id = Ash.Changeset.get_attribute(changeset, :geofence_id)

        case {poi_id, geofence_id} do
          {nil, nil} -> {:error, field: :geofence_id, message: "must specify geofence_id"}
          {nil, _} -> :ok
          _ -> {:error, field: :geofence_id, message: "cannot set both poi_id and geofence_id"}
        end
      end
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action(:list_by_poi) do
      authorize_if expr(exists(poi.event.memberships, user_id == ^actor(:id)))
    end

    policy action(:list_by_geofence) do
      authorize_if expr(exists(geofence.event.memberships, user_id == ^actor(:id)))
    end

    policy action_type(:read) do
      authorize_if expr(
                     exists(poi.event.memberships, user_id == ^actor(:id)) or
                       exists(geofence.event.memberships, user_id == ^actor(:id))
                   )
    end

    policy action(:create) do
      authorize_if expr(poi.creator_id == ^actor(:id))
    end

    policy action(:create_for_geofence) do
      authorize_if expr(geofence.creator_id == ^actor(:id))
    end

    policy action_type(:destroy) do
      authorize_if expr(uploader_id == ^actor(:id))
      authorize_if expr(exists(poi.event.memberships, user_id == ^actor(:id) and role == :admin))

      authorize_if expr(
                     exists(geofence.event.memberships, user_id == ^actor(:id) and role == :admin)
                   )
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
      description "URL path, e.g. /uploads/{owner_id}/{stored_filename}"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :poi, Platser.Map.Poi do
      allow_nil? true
    end

    belongs_to :geofence, Platser.Map.Geofence do
      allow_nil? true
    end

    belongs_to :uploader, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
