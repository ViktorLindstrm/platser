defmodule Platser.Repo.Migrations.AddJoinCodeLifecycleToEvents do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add :join_code_expires_at, :utc_datetime
      add :join_code_rotated_at, :utc_datetime
      add :join_code_invalidated_at, :utc_datetime
    end

    execute """
    UPDATE events
    SET
      join_code_expires_at = ends_at,
      join_code_rotated_at = COALESCE(inserted_at, starts_at)
    """

    alter table(:events) do
      modify :join_code_expires_at, :utc_datetime, null: false
      modify :join_code_rotated_at, :utc_datetime, null: false
    end
  end

  def down do
    alter table(:events) do
      remove :join_code_invalidated_at
      remove :join_code_rotated_at
      remove :join_code_expires_at
    end
  end
end
