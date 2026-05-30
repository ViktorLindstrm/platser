defmodule PlatserWeb.ProfileLive do
  use PlatserWeb, :live_view

  alias Platser.Accounts

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_update(current_user, :update_profile,
        actor: current_user,
        as: "user",
        domain: Accounts
      )
      |> to_form()

    {:ok, assign(socket, form: form)}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()} | {:reply, map(), Phoenix.LiveView.Socket.t()}
  def handle_event("validate", %{"user" => params}, socket) do
    form =
      AshPhoenix.Form.validate(socket.assigns.form.source, params)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated successfully")
         |> push_navigate(to: ~p"/events")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={@current_user}>
      <div class="mx-auto max-w-2xl px-4 py-12">
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-8 border-b border-gray-200">
            <h1 class="text-3xl font-bold text-gray-900">Profile Settings</h1>
          </div>

          <div class="px-6 py-8">
            <.form for={@form} id="profile-form" phx-change="validate" phx-submit="save">
              <div class="space-y-6">
                <div>
                  <label class="block text-sm font-medium text-gray-700">Email</label>
                  <input
                    type="email"
                    value={@current_user.email}
                    disabled
                    class="mt-2 w-full rounded-lg border border-gray-300 bg-gray-50 px-4 py-2 text-gray-700 cursor-not-allowed"
                  />
                  <p class="mt-2 text-sm text-gray-500">Your email cannot be changed</p>
                </div>

                <div>
                  <.input
                    field={@form[:display_name]}
                    type="text"
                    label="Display Name"
                    placeholder="Enter your display name"
                  />
                </div>
              </div>

              <div class="mt-8 flex gap-3">
                <button
                  type="submit"
                  class="rounded-lg bg-blue-600 px-6 py-2 text-sm font-medium text-white hover:bg-blue-700 transition-colors"
                >
                  Save Changes
                </button>
                <.link
                  navigate={~p"/events"}
                  class="rounded-lg bg-gray-200 px-6 py-2 text-sm font-medium text-gray-700 hover:bg-gray-300 transition-colors"
                >
                  Cancel
                </.link>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
