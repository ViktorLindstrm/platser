defmodule Platser.Release do
  @moduledoc """
  Tasks for running inside a Mix release, where Mix is not available.
  Called from the Docker entrypoint before the application starts.
  """

  @app :platser

  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok | {:error, term()}
  defp load_app do
    Application.load(@app)
  end
end
