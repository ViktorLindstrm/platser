defmodule Platser.Activity.Entry do
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
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(event.memberships, user_id == ^actor(:id)))
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
                    :exited_geofence
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
