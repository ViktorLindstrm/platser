defmodule Platser.Repo.Migrations.CreateUsersTable do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :email, :citext, null: false
      add :display_name, :string, null: false
      add :hashed_password, :string
      add :is_simulated, :boolean, null: false, default: false
      timestamps(type: :utc_datetime, default: fragment("now()"))
    end

    create unique_index(:users, [:email])
  end
end
