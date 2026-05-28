defmodule Platser.Repo.Migrations.EnableCitextExtension do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext")
  end
end
