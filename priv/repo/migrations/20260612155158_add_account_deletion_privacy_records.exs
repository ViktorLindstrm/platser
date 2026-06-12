defmodule Platser.Repo.Migrations.AddAccountDeletionPrivacyRecords do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :deleted_at, :utc_datetime
    end

    create table(:privacy_deletions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :requested_by_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :status, :text, null: false
      add :requested_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :outcome_counts, :map, null: false, default: %{}
    end

    create index(:users, [:deleted_at])
    create index(:privacy_deletions, [:user_id])
    create index(:privacy_deletions, [:requested_by_id])
  end
end
