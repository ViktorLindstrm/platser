defmodule Platser.Repo.Migrations.CreateTokensTable do
  use Ecto.Migration

  def change do
    create table(:tokens, primary_key: false) do
      add :jti, :string, primary_key: true, null: false
      add :subject, :string, null: false
      add :purpose, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :extra_data, :map
      timestamps(type: :utc_datetime, default: fragment("now()"))
    end

    create index(:tokens, [:subject])
    create index(:tokens, [:expires_at])
  end
end
