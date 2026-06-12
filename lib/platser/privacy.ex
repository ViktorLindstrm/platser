defmodule Platser.Privacy do
  use Ash.Domain,
    otp_app: :platser

  alias Platser.Accounts.User
  alias Platser.Privacy.AccountDeletion
  alias Platser.Privacy.Deletion
  alias Platser.Privacy.Export
  alias Platser.Privacy.ExportBuilder
  alias Platser.Privacy.Retention
  alias Platser.Privacy.RetentionRun

  resources do
    resource Deletion do
      define :list_account_deletions, action: :list_for_user
    end

    resource Export do
      define :list_account_exports, action: :list_for_user
      define :get_account_export, action: :read, get_by: [:id]
    end

    resource RetentionRun do
      define :list_retention_runs, action: :latest
    end
  end

  @spec delete_account(User.t()) ::
          {:ok, AccountDeletion.deletion_result()} | {:error, AccountDeletion.delete_error()}
  def delete_account(%User{} = actor), do: AccountDeletion.delete_account(actor)

  @spec run_retention() :: {:ok, Retention.run_result()} | Retention.run_error()
  def run_retention, do: Retention.run()

  @spec request_account_export(User.t()) :: {:ok, Export.t()} | {:error, term()}
  def request_account_export(%User{} = actor) do
    result =
      Export
      |> Ash.Changeset.for_create(:request, %{}, actor: actor)
      |> Ash.create()

    case result do
      {:ok, export} ->
        schedule_export(export)
        {:ok, export}

      {:error, _} = error ->
        error
    end
  end

  @spec schedule_export(Export.t()) :: :ok
  def schedule_export(%Export{id: export_id}) do
    if Application.get_env(:platser, :privacy_exports_async?, true) do
      case Task.Supervisor.start_child(Platser.Privacy.ExportSupervisor, fn ->
             ExportBuilder.build(export_id)
           end) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> :ok
      end
    else
      ExportBuilder.build(export_id)
    end
  end
end
