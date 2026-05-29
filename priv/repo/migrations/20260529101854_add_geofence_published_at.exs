defmodule Platser.Repo.Migrations.AddGeofencePublishedAt do
  use Ecto.Migration

  def change do
    alter table(:geofences) do
      add :published_at, :utc_datetime
    end
  end
end
