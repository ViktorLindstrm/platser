defmodule PlatserWeb.MediaController do
  use PlatserWeb, :controller

  alias Platser.Media.DiskPath
  alias Ash.Error.Forbidden

  @doc """
  Serves an uploaded file after verifying event-membership authorization via Ash policies.

  The URL path is matched against the canonical `path` field in `Media.Attachment`.
  The actual disk file is derived by `Platser.Media.DiskPath.for_attachment/1` —
  never from the raw URL — to prevent path traversal.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"path" => path_parts}) do
    actor = conn.assigns[:current_user]

    if is_nil(actor) do
      send_resp(conn, 403, "Forbidden")
    else
      canonical_path = "/uploads/" <> Enum.join(path_parts, "/")

      case Platser.Media.get_attachment_by_path(canonical_path, actor: actor) do
        {:ok, attachment} ->
          serve_file(conn, attachment)

        {:error, %Forbidden{}} ->
          send_resp(conn, 403, "Forbidden")

        _ ->
          send_resp(conn, 404, "Not Found")
      end
    end
  end

  @spec serve_file(Plug.Conn.t(), Platser.Media.Attachment.t()) :: Plug.Conn.t()
  defp serve_file(conn, attachment) do
    disk_path = DiskPath.for_attachment(attachment)

    cond do
      is_nil(disk_path) ->
        send_resp(conn, 404, "Not Found")

      not File.exists?(disk_path) ->
        send_resp(conn, 404, "Not Found")

      true ->
        conn
        |> put_resp_content_type(attachment.content_type)
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{attachment.filename}")
        )
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_file(200, disk_path)
    end
  end
end
