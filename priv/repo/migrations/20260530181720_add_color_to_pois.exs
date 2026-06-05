defmodule Platser.Repo.Migrations.AddColorToPois do
  use Ecto.Migration

  def change do
    alter table(:pois) do
      add :color, :string, null: false, default: "#3B82F6"
    end
  end
end
