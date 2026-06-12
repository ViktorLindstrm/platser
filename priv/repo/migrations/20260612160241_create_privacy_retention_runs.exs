defmodule Platser.Repo.Migrations.CreatePrivacyRetentionRuns do
  use Ecto.Migration

  def change do
    create table(:privacy_retention_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :status, :text, null: false
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :cutoffs, :map, null: false, default: %{}
      add :outcome_counts, :map, null: false, default: %{}
      add :failure_reason, :text
    end

    create index(:privacy_retention_runs, [:started_at])
    create index(:privacy_retention_runs, [:status])
  end
end
