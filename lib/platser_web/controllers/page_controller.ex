defmodule PlatserWeb.PageController do
  use PlatserWeb, :controller

  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/events")
    else
      render(conn, :home)
    end
  end

  @spec join_redirect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def join_redirect(conn, %{"code" => code}) when is_binary(code) and byte_size(code) > 0 do
    redirect(conn, to: ~p"/join/#{code}")
  end

  def join_redirect(conn, _params) do
    conn
    |> put_flash(:error, "Please enter a join code")
    |> redirect(to: ~p"/")
  end
end
