defmodule Platser.Repo.Migrations.AddAllowPublicCommentsToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :allow_public_comments, :boolean, default: false, null: false
    end
  end
end
