defmodule Platser.Repo.Migrations.CreatePrivacyExports do
  use Ecto.Migration

  def change do
    create table(:privacy_exports, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :status, :text, null: false
      add :format, :text, null: false
      add :path, :text
      add :size_bytes, :bigint
      add :checksum, :text
      add :requested_at, :utc_datetime, null: false
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      add :failed_at, :utc_datetime
      add :failure_reason, :text
    end

    create index(:privacy_exports, [:user_id, :requested_at])
    create index(:privacy_exports, [:status])
    create index(:privacy_exports, [:expires_at])
  end
end
