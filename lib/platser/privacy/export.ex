defmodule Platser.Privacy.Export do
  @type status :: :pending | :processing | :completed | :failed

  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Privacy,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "privacy_exports"
    repo(Platser.Repo)
  end

  actions do
    defaults [:read]

    read :list_for_user do
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [requested_at: :desc])
    end

    create :request do
      accept []
      change relate_actor(:user)
      change set_attribute(:status, :pending)
      change set_attribute(:format, "application/json")

      change fn changeset, _context ->
        now = DateTime.utc_now(:second)

        changeset
        |> Ash.Changeset.force_change_attribute(:requested_at, now)
        |> Ash.Changeset.force_change_attribute(:expires_at, DateTime.add(now, 7, :day))
      end
    end

    update :start_processing do
      accept []
      require_atomic? false
      change set_attribute(:status, :processing)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now(:second))
      end
    end

    update :complete do
      accept [:path, :size_bytes, :checksum]
      require_atomic? false
      change set_attribute(:status, :completed)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :completed_at, DateTime.utc_now(:second))
      end
    end

    update :fail do
      accept [:failure_reason]
      require_atomic? false
      change set_attribute(:status, :failed)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :failed_at, DateTime.utc_now(:second))
      end
    end
  end

  policies do
    policy action(:request) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if actor_attribute_equals(:superuser, true)
    end

    policy [action(:start_processing), action(:complete), action(:fail)] do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :processing, :completed, :failed]
    end

    attribute :format, :string do
      allow_nil? false
      public? true
    end

    attribute :path, :string do
      public? true
      sensitive? true
    end

    attribute :size_bytes, :integer do
      public? true
    end

    attribute :checksum, :string do
      public? true
    end

    attribute :requested_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime do
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :failed_at, :utc_datetime do
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end
  end

  relationships do
    belongs_to :user, Platser.Accounts.User do
      allow_nil? false
    end
  end
end
