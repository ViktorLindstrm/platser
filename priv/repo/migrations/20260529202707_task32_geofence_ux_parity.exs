defmodule Platser.Repo.Migrations.Task32GeofenceUxParity do
  use Ecto.Migration

  def change do
    # Add description and comment to geofences
    alter table(:geofences) do
      add :description, :text
      add :comment, :text
    end

    # Add comment to pois
    alter table(:pois) do
      add :comment, :text
    end

    # Drop NOT NULL on poi_id (existing FK constraint stays intact)
    execute(
      "ALTER TABLE media_attachments ALTER COLUMN poi_id DROP NOT NULL",
      "ALTER TABLE media_attachments ALTER COLUMN poi_id SET NOT NULL"
    )

    alter table(:media_attachments) do
      add :geofence_id,
          references(:geofences, type: :uuid, on_delete: :delete_all),
          null: true
    end

    # Enforce exactly one parent per attachment row
    create constraint(:media_attachments, :exactly_one_parent,
             check:
               "(poi_id IS NOT NULL AND geofence_id IS NULL) OR (poi_id IS NULL AND geofence_id IS NOT NULL)"
           )

    create index(:media_attachments, [:geofence_id])
  end
end
