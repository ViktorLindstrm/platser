defmodule PlatserWeb.Plugs.RequireSuperuser do
  @moduledoc """
  Plug that halts the request with a redirect to /sign-in unless the current
  user has `superuser: true`. Used to protect plug-based routes (e.g. the
  LiveDashboard forward) that cannot use the LiveView on_mount mechanism.

  Must run after `plug :load_from_session` so that `conn.assigns[:current_user]`
  is populated.
  """

  import Plug.Conn
  import Phoenix.Controller

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{superuser: true} ->
        conn

      _ ->
        conn
        |> redirect(to: "/sign-in")
        |> halt()
    end
  end
end
