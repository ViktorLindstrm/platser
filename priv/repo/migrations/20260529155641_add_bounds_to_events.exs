defmodule Platser.Repo.Migrations.AddBoundsToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :bounds, :geometry, null: true
    end
  end
end
