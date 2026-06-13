defmodule Platser.Map.Geofence do
  @manage_any_map_item_roles Platser.Events.MapAccess.roles_for_capability(:manage_any_map_item)

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Map,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Query

  alias Platser.Repo

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

    create :create do
      primary? true
      accept [:name, :description, :comment, :purpose, :geometry, :color, :event_id]

      change fn changeset, context ->
        if boundary_purpose?(changeset) do
          changeset
          |> Ash.Changeset.force_change_attribute(:visibility, :public)
          |> Ash.Changeset.force_change_attribute(:published_at, DateTime.utc_now())
          |> Platser.Map.Changes.BroadcastGeofencePublish.change([], context)
        else
          Ash.Changeset.force_change_attribute(changeset, :visibility, :private)
        end
      end

      change relate_actor(:creator)

      validate fn changeset, _ ->
        validate_geometry(Ash.Changeset.get_attribute(changeset, :geometry))
      end

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
      end

      validate fn changeset, _ ->
        validate_boundary_uniqueness(changeset)
      end
    end

    update :publish do
      accept []
      require_atomic? false

      validate attribute_equals(:visibility, :private) do
        message "Geofence is already published"
      end

      change set_attribute(:visibility, :public)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
      end

      change Platser.Map.Changes.BroadcastGeofencePublish
    end

    update :update do
      accept [:name, :description, :comment, :purpose, :color]
      require_atomic? false

      validate attribute_equals(:visibility, :private) do
        message "can only edit draft geofences"
      end

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
      end

      validate fn changeset, _ ->
        validate_boundary_uniqueness(changeset)
      end
    end

    update :update_metadata do
      accept [:name, :description, :color]
      require_atomic? false

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
      end
    end

    update :update_comment do
      accept [:comment]
      require_atomic? false

      change Platser.Map.Changes.BroadcastCommentUpdate
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
                          exists(
                            event.memberships,
                            user_id == ^actor(:id) and
                              role in ^@manage_any_map_item_roles
                          ))
                   )
    end

    policy action_type(:create) do
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id)))
    end

    policy action(:update) do
      authorize_if expr(creator_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )
    end

    policy action(:update_metadata) do
      authorize_if expr(creator_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )
    end

    policy action(:update_comment) do
      authorize_if expr(creator_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )

      authorize_if expr(
                     event.allow_participant_comments == true and
                       exists(event.memberships, user_id == ^actor(:id))
                   )
    end

    policy action(:publish) do
      authorize_if expr(creator_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
                   )
    end

    policy action_type(:destroy) do
      authorize_if expr(creator_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and
                         role in ^@manage_any_map_item_roles
                     )
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

    attribute :published_at, :utc_datetime
    attribute :description, :string
    attribute :comment, :string, sensitive?: true
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :creator, Platser.Accounts.User do
      allow_nil? false
    end

    has_many :attachments, Platser.Media.Attachment do
      destination_attribute :geofence_id
    end
  end

  @spec validate_geometry(term()) :: :ok | {:error, keyword()}
  defp validate_geometry(%Geo.Polygon{coordinates: [ring | _]}) when length(ring) >= 4, do: :ok

  defp validate_geometry(_),
    do: {:error, field: :geometry, message: "must be a polygon with at least 3 vertices"}

  @spec validate_color(term()) :: :ok | {:error, keyword()}
  defp validate_color(color)
       when is_binary(color) do
    if Regex.match?(~r/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/, color) do
      :ok
    else
      {:error, field: :color, message: "must be a valid hex color (e.g. #ff0000)"}
    end
  end

  defp validate_color(_),
    do: {:error, field: :color, message: "must be a valid hex color (e.g. #ff0000)"}

  @spec validate_boundary_uniqueness(term()) :: :ok | {:error, keyword()}
  defp validate_boundary_uniqueness(changeset) do
    purpose = Ash.Changeset.get_attribute(changeset, :purpose)

    if purpose == :boundary and boundary_geofence_exists?(changeset) do
      {:error, field: :purpose, message: "only one boundary geofence is allowed per event"}
    else
      :ok
    end
  end

  @spec boundary_geofence_exists?(term()) :: boolean()
  defp boundary_geofence_exists?(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    geofence_id = Ash.Changeset.get_attribute(changeset, :id)

    if is_nil(event_id) do
      false
    else
      query =
        from g in "geofences",
          where: g.event_id == type(^event_id, :binary_id),
          where: g.purpose == "boundary",
          select: g.id

      query =
        if is_nil(geofence_id) do
          query
        else
          from g in query,
            where: g.id != type(^geofence_id, :binary_id)
        end

      Repo.aggregate(query, :count, :id) > 0
    end
  end

  @spec boundary_purpose?(term()) :: boolean()
  defp boundary_purpose?(changeset) do
    Ash.Changeset.get_attribute(changeset, :purpose) == :boundary
  end
end
