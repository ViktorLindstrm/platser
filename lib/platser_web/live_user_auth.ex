defmodule PlatserWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use PlatserWeb, :verified_routes

  @doc """
  Assigns the current user from the session to the socket if not already present.
  Used for nested LiveViews.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:current_user, _params, session, socket) do
    socket = assign_new(socket, :current_user, fn -> get_current_user(session) end)
    {:cont, socket}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:ensure_superuser, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{superuser: true} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  @spec get_current_user(map()) :: Platser.Accounts.User.t() | nil
  defp get_current_user(_session), do: nil
end
