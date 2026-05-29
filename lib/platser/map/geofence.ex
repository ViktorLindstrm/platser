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

    create :create do
      primary? true
      accept [:name, :purpose, :geometry, :color, :event_id]
      change set_attribute(:visibility, :private)
      change relate_actor(:creator)

      validate fn changeset, _ ->
        validate_geometry(Ash.Changeset.get_attribute(changeset, :geometry))
      end

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
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
      accept [:name, :purpose, :color]
      require_atomic? false

      validate attribute_equals(:visibility, :private) do
        message "can only edit draft geofences"
      end

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
      end
    end

    update :update_metadata do
      accept [:name, :color]
      require_atomic? false

      validate fn changeset, _ ->
        validate_color(Ash.Changeset.get_attribute(changeset, :color))
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

    policy action(:update_metadata) do
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
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :creator, Platser.Accounts.User do
      allow_nil? false
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
end
