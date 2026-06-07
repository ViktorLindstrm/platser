import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/platser start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :platser, PlatserWeb.Endpoint, server: true
end

config :platser, PlatserWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :platser, Platser.Repo,
    # ssl: true,
    url: database_url,
    types: Platser.PostgresTypes,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "platser.lan"
  port = String.to_integer(System.get_env("PORT", "4000"))
  scheme = System.get_env("PHX_SCHEME", "http")

  url_port =
    cond do
      scheme == "https" && port == 443 -> []
      scheme == "http" && port == 80 -> []
      true -> [port: port]
    end

  config :platser, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  extra_hosts =
    System.get_env("PHX_EXTRA_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  allowed_origins =
    (["//#{host}"] ++ Enum.map(extra_hosts, &"//#{&1}"))
    |> Enum.uniq()

  config :platser, PlatserWeb.Endpoint,
    url: [host: host, scheme: scheme] ++ url_port,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: allowed_origins,
    secret_key_base: secret_key_base

  config :platser, token_signing_secret: secret_key_base
end
