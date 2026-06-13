defmodule Platser.Repo.Migrations.CreateManagerAuditEntries do
  use Ecto.Migration

  def change do
    create table(:manager_audit_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :action, :string, null: false
      add :target_user_id, :uuid
      add :old_value, :string
      add :new_value, :string
      add :message, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      add :event_id, :uuid, null: false
      add :actor_id, :uuid, null: false
    end

    create index(:manager_audit_entries, [:event_id, :inserted_at])
    create index(:manager_audit_entries, [:actor_id])
    create index(:manager_audit_entries, [:target_user_id])
  end
end
