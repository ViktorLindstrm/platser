defmodule Platser.Repo.Migrations.AddCheckInCoordinatesToEntries do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      add :lat, :float
      add :lng, :float
    end
  end
end
