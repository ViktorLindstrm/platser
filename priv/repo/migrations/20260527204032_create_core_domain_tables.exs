defmodule Platser.Repo.Migrations.CreateCoreDomainTables do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :string, null: false
      add :description, :string
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :join_code, :string, null: false
      add :creator_id, :uuid, null: false
    end

    create unique_index(:events, [:join_code])

    create table(:memberships, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :role, :string, null: false
      add :joined_at, :utc_datetime, null: false, default: fragment("now()")
      add :event_id, :uuid, null: false
      add :user_id, :uuid, null: false
    end

    create unique_index(:memberships, [:event_id, :user_id])

    create table(:pois, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :string, null: false
      add :description, :string
      add :category, :string, null: false
      add :location, :geometry, null: false
      add :visibility, :string, null: false
      add :published_at, :utc_datetime
      add :event_id, :uuid, null: false
      add :creator_id, :uuid, null: false
    end

    create index(:pois, [:location], using: :gist)

    create table(:geofences, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :name, :string, null: false
      add :purpose, :string, null: false
      add :geometry, :geometry, null: false
      add :visibility, :string, null: false
      add :color, :string, null: false
      add :event_id, :uuid, null: false
      add :creator_id, :uuid, null: false
    end

    create index(:geofences, [:geometry], using: :gist)

    create table(:entries, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :action, :string, null: false
      add :subject_type, :string, null: false
      add :subject_id, :uuid, null: false
      add :message, :string, null: false
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      add :event_id, :uuid, null: false
      add :actor_id, :uuid, null: false
    end
  end
end
