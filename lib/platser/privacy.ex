defmodule Platser.Privacy do
  use Ash.Domain,
    otp_app: :platser

  alias Platser.Accounts.User
  alias Platser.Privacy.Export
  alias Platser.Privacy.ExportBuilder

  resources do
    resource Export do
      define :list_account_exports, action: :list_for_user
      define :get_account_export, action: :read, get_by: [:id]
    end
  end

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
