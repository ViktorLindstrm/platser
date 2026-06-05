defmodule Platser.Repo.Migrations.EnablePostgisExtension do
  use Ecto.Migration

  def change do
    execute """
            DO $$
            BEGIN
              IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'postgis') THEN
                EXECUTE 'CREATE EXTENSION IF NOT EXISTS postgis';
              END IF;
            END
            $$;
            """,
            """
            DO $$
            BEGIN
              IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
                EXECUTE 'DROP EXTENSION IF EXISTS postgis';
              END IF;
            END
            $$;
            """
  end
end
