defmodule Platser.Repo do
  use Ecto.Repo,
    otp_app: :platser,
    adapter: Ecto.Adapters.Postgres
end
