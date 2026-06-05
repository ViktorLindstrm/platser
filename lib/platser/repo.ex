defmodule Platser.Repo do
  use AshPostgres.Repo,
    otp_app: :platser

  @spec installed_extensions() :: [String.t()]
  def installed_extensions, do: ["postgis", "citext", "ash-functions"]

  @spec min_pg_version() :: Version.t()
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
