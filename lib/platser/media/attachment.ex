defmodule Platser.Media.Attachment do
  @opaque_stored_filename_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/
  @safe_filenames ~w(image.jpg image.png image.webp)
  @supported_content_types ~w(image/jpeg image/png image/webp)
  @manage_any_map_item_roles Platser.Events.MapAccess.roles_for_capability(:manage_any_map_item)

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

    read :get_by_path do
      argument :path, :string, allow_nil?: false
      filter expr(path == ^arg(:path))
      get? true
    end

    create :create do
      accept [:filename, :stored_filename, :content_type, :path, :poi_id]
      change relate_actor(:uploader)

      validate fn changeset, _ ->
        case validate_parent(changeset, :poi) do
          :ok -> validate_upload_metadata(changeset)
          {:error, _} = error -> error
        end
      end
    end

    create :create_for_geofence do
      accept [:filename, :stored_filename, :content_type, :path, :geofence_id]
      change relate_actor(:uploader)

      validate fn changeset, _ ->
        case validate_parent(changeset, :geofence) do
          :ok -> validate_upload_metadata(changeset)
          {:error, _} = error -> error
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

      authorize_if expr(
                     exists(
                       poi.event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )

      authorize_if expr(
                     exists(
                       geofence.event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :filename, :string do
      allow_nil? false
      description "Privacy-safe display filename"
    end

    attribute :stored_filename, :string do
      allow_nil? false
      description "Server-generated opaque filename"
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

  identities do
    identity :unique_path, [:path]
  end

  @spec validate_parent(Ash.Changeset.t(), :poi | :geofence) :: :ok | {:error, keyword()}
  defp validate_parent(changeset, :poi) do
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

  defp validate_parent(changeset, :geofence) do
    poi_id = Ash.Changeset.get_attribute(changeset, :poi_id)
    geofence_id = Ash.Changeset.get_attribute(changeset, :geofence_id)

    case {poi_id, geofence_id} do
      {nil, nil} -> {:error, field: :geofence_id, message: "must specify geofence_id"}
      {nil, _} -> :ok
      _ -> {:error, field: :geofence_id, message: "cannot set both poi_id and geofence_id"}
    end
  end

  @spec validate_upload_metadata(Ash.Changeset.t()) :: :ok | {:error, keyword()}
  defp validate_upload_metadata(changeset) do
    filename = Ash.Changeset.get_attribute(changeset, :filename)
    stored_filename = Ash.Changeset.get_attribute(changeset, :stored_filename)
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    path = Ash.Changeset.get_attribute(changeset, :path)

    owner_id =
      Ash.Changeset.get_attribute(changeset, :poi_id) ||
        Ash.Changeset.get_attribute(changeset, :geofence_id)

    cond do
      filename not in @safe_filenames ->
        {:error, field: :filename, message: "must use a privacy-safe display filename"}

      not is_binary(stored_filename) or
          not Regex.match?(@opaque_stored_filename_regex, stored_filename) ->
        {:error, field: :stored_filename, message: "must be an opaque generated image filename"}

      content_type not in @supported_content_types ->
        {:error, field: :content_type, message: "must be a supported image content type"}

      not is_binary(path) or path != "/uploads/#{owner_id}/#{stored_filename}" ->
        {:error, field: :path, message: "must match the canonical upload path"}

      true ->
        :ok
    end
  end
end
