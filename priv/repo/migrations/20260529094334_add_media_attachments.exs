defmodule Platser.Repo.Migrations.AddMediaAttachments do
  use Ecto.Migration

  def change do
    create table(:media_attachments, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :filename, :string, null: false
      add :stored_filename, :string, null: false
      add :content_type, :string, null: false
      add :path, :string, null: false
      add :poi_id, references(:pois, type: :uuid, on_delete: :delete_all), null: false
      add :uploader_id, :uuid, null: false
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:media_attachments, [:poi_id])
  end
end
