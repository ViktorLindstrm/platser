defmodule Platser.Accounts.User do
  use Ash.Resource,
    otp_app: :platser,
    domain: Platser.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  postgres do
    table "users"
    repo(Platser.Repo)
  end

  authentication do
    strategies do
      password :password do
        hashed_password_field :hashed_password
        identity_field :email
        register_action_accept [:display_name]
      end
    end

    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Platser.Accounts.Token
      signing_secret Platser.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  field_policies do
    field_policy [:display_name, :is_simulated, :is_guest, :deleted_at] do
      authorize_if always()
    end

    field_policy :email do
      authorize_if expr(id == ^actor(:id))
      authorize_if actor_attribute_equals(:superuser, true)
    end
  end

  actions do
    defaults [:read]

    create :register do
      primary? true
      accept [:email, :display_name]
      argument :password, :string, allow_nil?: false, sensitive?: true
      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true
      validate confirm(:password, :password_confirmation)
      change AshAuthentication.Strategy.Password.HashPasswordChange
    end

    create :create_simulated do
      description "Creates a dev-only simulated user (is_simulated: true, no password required)."
      accept [:email, :display_name]
      change set_attribute(:is_simulated, true)
    end

    create :create_guest do
      description "Auto-provisions a temporary guest user with a synthetic email and no password."
      accept [:display_name]

      change fn changeset, _ ->
        token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        synthetic_email = "guest_#{token}@platser.guest"

        display_name =
          case Ash.Changeset.get_attribute(changeset, :display_name) do
            nil -> "Guest_#{String.slice(token, 0, 6)}"
            "" -> "Guest_#{String.slice(token, 0, 6)}"
            name -> name
          end

        changeset
        |> Ash.Changeset.force_change_attribute(:email, synthetic_email)
        |> Ash.Changeset.force_change_attribute(:display_name, display_name)
        |> Ash.Changeset.force_change_attribute(:is_guest, true)
      end
    end

    update :upgrade_to_registered do
      description "Upgrades a guest user to a registered account with a real email and password."
      require_atomic? false
      accept [:email, :display_name]
      argument :password, :string, allow_nil?: false, sensitive?: true
      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      validate attribute_equals(:is_guest, true),
        message: "only guest accounts can be upgraded via this action"

      validate confirm(:password, :password_confirmation)
      change set_context(%{strategy_name: :password})
      change set_attribute(:is_guest, false)
      change AshAuthentication.Strategy.Password.HashPasswordChange
    end

    update :update_profile do
      description "Allows a user to update their display name."
      require_atomic? false
      accept [:display_name]
      validate present(:display_name)
    end

    update :set_superuser do
      description "Internal: set the superuser flag. Must be called with authorize?: false."
      require_atomic? false
      accept [:superuser]
    end

    update :anonymize_for_deletion do
      description "Internal: anonymizes credentials and direct identifiers for deleted accounts."
      require_atomic? false
      accept [:deleted_at]

      change fn changeset, _context ->
        id = Ash.Changeset.get_attribute(changeset, :id)

        changeset
        |> Ash.Changeset.force_change_attribute(:email, "deleted_#{id}@platser.deleted")
        |> Ash.Changeset.force_change_attribute(:display_name, "Deleted user")
        |> Ash.Changeset.force_change_attribute(:hashed_password, nil)
        |> Ash.Changeset.force_change_attribute(:is_guest, false)
        |> Ash.Changeset.force_change_attribute(:superuser, false)
      end
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
      authorize_if actor_attribute_equals(:superuser, true)

      authorize_if expr(
                     exists(
                       memberships,
                       exists(event.memberships, user_id == ^actor(:id))
                     )
                   )
    end

    policy action(:create_simulated) do
      authorize_if actor_present()
    end

    policy action(:create_guest) do
      authorize_if always()
    end

    policy action(:upgrade_to_registered) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:set_superuser) do
      forbid_if always()
    end

    policy action(:anonymize_for_deletion) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true, sensitive?: true
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: true, sensitive?: true
    attribute :is_simulated, :boolean, default: false, public?: true
    attribute :is_guest, :boolean, default: false, public?: true
    attribute :superuser, :boolean, default: false, public?: false
    attribute :deleted_at, :utc_datetime, public?: true
  end

  relationships do
    has_many :memberships, Platser.Events.Membership
  end

  identities do
    identity :unique_email, [:email] do
      pre_check_with Platser.Accounts
    end
  end
end
