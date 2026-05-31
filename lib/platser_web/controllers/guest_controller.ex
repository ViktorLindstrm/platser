defmodule PlatserWeb.GuestController do
  use PlatserWeb, :controller

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias Platser.Accounts
  alias Platser.Events

  @spec guest_join(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def guest_join(conn, %{"code" => code} = params) do
    display_name = Map.get(params, "display_name", "")

    with {:ok, event} <- Events.get_event_by_join_code(code, authorize?: false),
         {:ok, guest} <- Accounts.create_guest_user(display_name, authorize?: false),
         {:ok, _membership} <- Events.join_event(code, actor: guest),
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(guest) do
      guest_with_token = %{guest | __metadata__: Map.put(guest.__metadata__, :token, token)}

      conn
      |> store_in_session(guest_with_token)
      |> redirect(to: ~p"/events/#{event.id}/map")
    else
      {:ok, nil} ->
        conn
        |> put_flash(:error, "Invalid or expired invite link.")
        |> redirect(to: ~p"/join/#{code}")

      {:error, _} ->
        conn
        |> put_flash(:error, "Failed to join as guest. Please try again.")
        |> redirect(to: ~p"/join/#{code}")
    end
  end

  @spec upgrade_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upgrade_account(conn, params) do
    user = conn.assigns[:current_user]

    if is_nil(user) do
      conn
      |> put_flash(:error, "You must be signed in to upgrade your account.")
      |> redirect(to: ~p"/sign-in")
    else
      upgrade_params = %{
        email: Map.get(params, "email", ""),
        display_name: Map.get(params, "display_name", user.display_name),
        password: Map.get(params, "password", ""),
        password_confirmation: Map.get(params, "password_confirmation", "")
      }

      case Accounts.upgrade_guest_user(user, upgrade_params, actor: user) do
        {:ok, upgraded_user} ->
          {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(upgraded_user)

          user_with_token = %{
            upgraded_user
            | __metadata__: Map.put(upgraded_user.__metadata__, :token, token)
          }

          conn
          |> store_in_session(user_with_token)
          |> put_flash(:info, "Your account has been upgraded! Welcome.")
          |> redirect(to: ~p"/events")

        {:error, %Ash.Error.Invalid{} = error} ->
          messages =
            error.errors
            |> Enum.map_join(", ", fn e -> Map.get(e, :message, "unknown error") end)

          conn
          |> put_flash(:error, "Could not upgrade account: #{messages}")
          |> redirect(to: ~p"/upgrade")

        {:error, _} ->
          conn
          |> put_flash(:error, "Something went wrong. Please try again.")
          |> redirect(to: ~p"/upgrade")
      end
    end
  end
end
