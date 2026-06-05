defmodule Platser.Repo.Migrations.AddBoundaryGeofenceUniqueness do
  use Ecto.Migration

  def change do
    create unique_index(:geofences, [:event_id],
             where: "purpose = 'boundary'",
             name: :geofences_boundary_event_id_index
           )
  end
end
