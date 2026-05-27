defmodule PlatserWeb.PageController do
  use PlatserWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
