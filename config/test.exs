import Config
config :platser, token_signing_secret: "9hzlNMxKB8vO5cEoZ6X+WAk/r1rv4Eh2"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :platser, Platser.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "platser_test#{System.get_env("MIX_TEST_PARTITION")}",
  types: Platser.PostgresTypes,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :platser, PlatserWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7Sc27NPt4M33C84YIDdisPMPeQvz4ORh/3t9DumNLs6Wx9xlU5gsaCB4urDVi6UR",
  server: false

# In test we don't send emails
config :platser, Platser.Mailer, adapter: Swoosh.Adapters.Test

config :platser,
       :geocoder_req_options,
       plug: {Req.Test, Platser.Map.Search.Geocoder}

config :platser,
       :geocoder_rate_limit_public?,
       false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
