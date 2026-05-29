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
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: true, sensitive?: true
    attribute :is_simulated, :boolean, default: false, public?: true
  end

  identities do
    identity :unique_email, [:email] do
      pre_check_with Platser.Accounts
    end
  end
end
