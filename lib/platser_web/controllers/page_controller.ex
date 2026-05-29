defmodule PlatserWeb.PageController do
  use PlatserWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/events")
    else
      render(conn, :home)
    end
  end
end
