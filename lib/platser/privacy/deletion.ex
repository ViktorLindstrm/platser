defmodule Platser.Privacy.Deletion do
  @type status :: :completed | :failed

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Privacy,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "privacy_deletions"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_for_user do
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [requested_at: :desc])
    end

    create :record do
      accept [:user_id, :requested_by_id, :status, :requested_at, :completed_at, :outcome_counts]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if actor_attribute_equals(:superuser, true)
    end

    policy action(:record) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:completed, :failed]
    end

    attribute :requested_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :outcome_counts, :map do
      allow_nil? false
      default %{}
      public? true
    end
  end

  relationships do
    belongs_to :user, Platser.Accounts.User do
      allow_nil? false
    end

    belongs_to :requested_by, Platser.Accounts.User do
      allow_nil? false
      source_attribute :requested_by_id
    end
  end
end
