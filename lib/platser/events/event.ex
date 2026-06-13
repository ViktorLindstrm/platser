defmodule Platser.Events.Event do
  @manage_event_settings_roles Platser.Events.MapAccess.roles_for_capability(
                                 :manage_event_settings
                               )
  @manage_join_code_roles Platser.Events.MapAccess.roles_for_capability(:manage_join_code)

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

    read :list_for_user do
      description "List all events the current actor is a member of."
      filter expr(exists(memberships, user_id == ^actor(:id)))
      prepare build(sort: [starts_at: :asc], load: [:memberships])
    end

    read :get_by_join_code do
      description "Look up an event by its active invite join code."
      get? true
      argument :join_code, :string, allow_nil?: false

      filter expr(
               join_code == ^arg(:join_code) and is_nil(join_code_invalidated_at) and
                 join_code_expires_at > now()
             )
    end

    update :regenerate_join_code do
      description "Replaces the event's join code with a freshly generated one."
      require_atomic? false
      change Platser.Events.Changes.GenerateJoinCode
    end

    update :invalidate_join_code do
      description "Invalidates the current event join code without issuing a replacement."
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :join_code_invalidated_at,
          DateTime.utc_now(:second)
        )
      end
    end

    update :update_settings do
      description "Updates event settings. Full manager only."
      require_atomic? false

      accept [
        :allow_public_comments,
        :allow_participant_comments,
        :allow_participant_check_ins,
        :allow_participant_live_location
      ]

      change fn changeset, _context ->
        case Ash.Changeset.fetch_change(changeset, :allow_participant_comments) do
          {:ok, allow?} ->
            Ash.Changeset.force_change_attribute(changeset, :allow_public_comments, allow?)

          :error ->
            case Ash.Changeset.fetch_change(changeset, :allow_public_comments) do
              {:ok, allow?} ->
                Ash.Changeset.force_change_attribute(
                  changeset,
                  :allow_participant_comments,
                  allow?
                )

              :error ->
                changeset
            end
        end
      end
    end

    update :set_bounds do
      description "Sets or replaces the geographic bounds for the event map."
      require_atomic? false
      argument :bounds, Platser.Types.Geometry, allow_nil?: true
      change set_attribute(:bounds, arg(:bounds))
    end

    update :update do
      description "Updates event name, description, and dates. Full manager only."
      require_atomic? false
      accept [:name, :description, :starts_at, :ends_at]
      change Platser.Events.Changes.BroadcastEventUpdate
    end
  end

  policies do
    policy action(:create) do
      forbid_if actor_attribute_equals(:is_guest, true)
      authorize_if actor_present()
    end

    policy action(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
    end

    policy action(:list_for_user) do
      authorize_if actor_present()
    end

    policy action(:get_by_join_code) do
      authorize_if always()
    end

    policy action(:regenerate_join_code) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and role in ^@manage_join_code_roles
                     )
                   )
    end

    policy action(:invalidate_join_code) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and role in ^@manage_join_code_roles
                     )
                   )
    end

    policy action(:update_settings) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and role in ^@manage_event_settings_roles
                     )
                   )
    end

    policy action(:set_bounds) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and role in ^@manage_event_settings_roles
                     )
                   )
    end

    policy action(:update) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and role in ^@manage_event_settings_roles
                     )
                   )
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
      sensitive? true
    end

    attribute :join_code_expires_at, :utc_datetime do
      allow_nil? false
    end

    attribute :join_code_rotated_at, :utc_datetime do
      allow_nil? false
    end

    attribute :join_code_invalidated_at, :utc_datetime

    attribute :bounds, Platser.Types.Geometry

    attribute :allow_public_comments, :boolean do
      allow_nil? false
      default false
    end

    attribute :allow_participant_comments, :boolean do
      allow_nil? false
      default false
    end

    attribute :allow_participant_check_ins, :boolean do
      allow_nil? false
      default true
    end

    attribute :allow_participant_live_location, :boolean do
      allow_nil? false
      default true
    end

    create_timestamp :inserted_at
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
