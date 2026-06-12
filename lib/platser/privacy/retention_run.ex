defmodule Platser.Privacy.RetentionRun do
  @type status :: :completed | :failed

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Privacy,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "privacy_retention_runs"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :latest do
      prepare build(sort: [started_at: :desc], limit: 20)
    end

    create :record do
      accept [:status, :started_at, :completed_at, :cutoffs, :outcome_counts, :failure_reason]
    end
  end

  policies do
    policy action_type(:read) do
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

    attribute :started_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :cutoffs, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :outcome_counts, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end
  end
end
