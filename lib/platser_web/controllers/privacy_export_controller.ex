defmodule PlatserWeb.PrivacyExportController do
  use PlatserWeb, :controller

  alias Ash.Error.Forbidden
  alias Platser.Privacy.ExportStore

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => id}) do
    actor = conn.assigns[:current_user]

    if is_nil(actor) do
      send_resp(conn, 403, "Forbidden")
    else
      case Platser.Privacy.get_account_export(id, actor: actor) do
        {:ok, export} -> send_export(conn, export)
        {:error, %Forbidden{}} -> send_resp(conn, 403, "Forbidden")
        _ -> send_resp(conn, 404, "Not Found")
      end
    end
  end

  @spec send_export(Plug.Conn.t(), Platser.Privacy.Export.t()) :: Plug.Conn.t()
  defp send_export(conn, export) do
    path = ExportStore.path_for_export(export)

    cond do
      export.status != :completed ->
        send_resp(conn, 404, "Not Found")

      expired?(export) ->
        send_resp(conn, 410, "Gone")

      is_nil(path) or not File.exists?(path) ->
        send_resp(conn, 404, "Not Found")

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_download({:file, path}, filename: "platser-account-export-#{export.id}.json")
    end
  end

  @spec expired?(Platser.Privacy.Export.t()) :: boolean()
  defp expired?(export) do
    DateTime.compare(export.expires_at, DateTime.utc_now(:second)) != :gt
  end
end
