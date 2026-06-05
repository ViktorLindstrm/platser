defmodule Platser.Repo.Migrations.RenameTokensInsertedAtToCreatedAt do
  use Ecto.Migration

  def change do
    rename table(:tokens), :inserted_at, to: :created_at
  end
end
