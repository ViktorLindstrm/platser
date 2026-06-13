defmodule Platser.Activity.Entry do
  @manage_participation_roles Platser.Events.MapAccess.roles_for_capability(:manage_any_map_item)

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Activity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "entries"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_by_event do
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id))
      prepare build(sort: [inserted_at: :desc], limit: 50)
    end

    read :list_by_subject do
      argument :subject_id, :uuid, allow_nil?: false
      argument :subject_type, :string, allow_nil?: false
      argument :event_id, :uuid, allow_nil?: false

      filter expr(
               subject_id == ^arg(:subject_id) and
                 subject_type == ^arg(:subject_type) and
                 event_id == ^arg(:event_id)
             )

      prepare build(sort: [inserted_at: :desc], limit: 20)
    end

    read :list_check_ins_by_event do
      argument :event_id, :uuid, allow_nil?: false
      filter expr(event_id == ^arg(:event_id) and action == :checked_in)
      prepare build(sort: [inserted_at: :desc], limit: 20)
    end

    create :create do
      primary? true
      accept [:action, :subject_type, :subject_id, :message, :event_id]
      change relate_actor(:actor)
    end

    create :check_in do
      accept [:event_id, :lat, :lng, :message]

      validate present([:lat, :lng])
      validate numericality(:lat, greater_than_or_equal_to: -90.0, less_than_or_equal_to: 90.0)
      validate numericality(:lng, greater_than_or_equal_to: -180.0, less_than_or_equal_to: 180.0)

      change relate_actor(:actor)
      change Platser.Activity.Entry.Changes.CheckIn
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id)))
    end

    policy action(:create) do
      authorize_if expr(
                     action != :comment_added and
                       exists(event.memberships, user_id == ^actor(:id))
                   )

      authorize_if expr(
                     action == :comment_added and
                       exists(
                         event.memberships,
                         user_id == ^actor(:id) and role in ^@manage_participation_roles
                       )
                   )

      authorize_if expr(
                     action == :comment_added and event.allow_participant_comments == true and
                       exists(event.memberships, user_id == ^actor(:id))
                   )
    end

    policy action(:check_in) do
      authorize_if expr(
                     exists(
                       event.memberships,
                       user_id == ^actor(:id) and role in ^@manage_participation_roles
                     )
                   )

      authorize_if expr(
                     event.allow_participant_check_ins == true and
                       exists(event.memberships, user_id == ^actor(:id))
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :action, :atom do
      allow_nil? false

      constraints one_of: [
                    :poi_published,
                    :geofence_published,
                    :joined_event,
                    :comment_added,
                    :entered_geofence,
                    :exited_geofence,
                    :checked_in
                  ]
    end

    attribute :subject_type, :string do
      allow_nil? false
    end

    attribute :subject_id, :uuid do
      allow_nil? false
    end

    attribute :message, :string do
      allow_nil? false
    end

    attribute :lat, :float do
      allow_nil? true
      sensitive? true
    end

    attribute :lng, :float do
      allow_nil? true
      sensitive? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :event, Platser.Events.Event do
      allow_nil? false
    end

    belongs_to :actor, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
