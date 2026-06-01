defmodule Platser.Repo.Migrations.AddUniqueIndexToMediaAttachmentsPath do
  use Ecto.Migration

  def change do
    create unique_index(:media_attachments, [:path])
  end
end
