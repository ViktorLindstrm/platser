defmodule PlatserWeb.ProfileLive do
  use PlatserWeb, :live_view

  alias Platser.Accounts
  alias Platser.Privacy

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    current_user = load_current_user(socket.assigns.current_user)

    form =
      AshPhoenix.Form.for_update(current_user, :update_profile,
        actor: current_user,
        as: "user",
        domain: Accounts
      )
      |> to_form()

    {:ok,
     socket
     |> assign(current_user: current_user)
     |> assign(form: form)
     |> assign(deletion_form: to_form(%{"confirmation" => ""}, as: :delete))
     |> assign_exports(current_user)
     |> maybe_schedule_export_refresh()}
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

  def handle_event("request_export", _params, socket) do
    current_user = socket.assigns.current_user

    case Privacy.request_account_export(current_user) do
      {:ok, _export} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account export requested")
         |> assign_exports(current_user)
         |> maybe_schedule_export_refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not request account export")}
    end
  end

  def handle_event("delete_account", %{"delete" => %{"confirmation" => confirmation}}, socket) do
    if confirmation == "DELETE" do
      case Privacy.delete_account(socket.assigns.current_user) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> put_flash(:info, "Account deleted")
           |> redirect(to: ~p"/sign-out")}

        {:error, :already_deleted} ->
          {:noreply, redirect(socket, to: ~p"/sign-out")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete account")}
      end
    else
      {:noreply, put_flash(socket, :error, "Type DELETE to confirm account deletion")}
    end
  end

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh_exports, socket) do
    {:noreply,
     socket
     |> assign_exports(socket.assigns.current_user)
     |> maybe_schedule_export_refresh()}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={@current_user}>
      <div class="mx-auto max-w-3xl px-4 py-12">
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

        <section class="mt-8 bg-white rounded-lg shadow" id="privacy-export-panel">
          <div class="px-6 py-6 border-b border-gray-200">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="text-xl font-semibold text-gray-900">Account Data Export</h2>
                <p class="mt-1 text-sm text-gray-500">
                  Request a JSON copy of the account data linked to your user.
                </p>
              </div>
              <button
                id="request-account-export"
                type="button"
                phx-click="request_export"
                class="inline-flex items-center justify-center rounded-lg bg-gray-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-gray-700"
              >
                Request Export
              </button>
            </div>
          </div>

          <div class="px-6 py-6">
            <div id="privacy-export-list" class="space-y-3">
              <div :if={@exports == []} id="privacy-export-empty" class="text-sm text-gray-500">
                No exports requested yet.
              </div>

              <div
                :for={export <- @exports}
                id={"privacy-export-#{export.id}"}
                class="flex flex-col gap-3 rounded-lg border border-gray-200 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <div class="text-sm font-medium text-gray-900">
                    Requested {format_datetime(export.requested_at)}
                  </div>
                  <div class="mt-1 text-sm text-gray-500">
                    Status: {format_status(export)} · Expires {format_datetime(export.expires_at)}
                  </div>
                </div>

                <.link
                  :if={downloadable?(export)}
                  id={"download-account-export-#{export.id}"}
                  href={~p"/privacy/exports/#{export.id}/download"}
                  class="inline-flex items-center justify-center rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-700"
                >
                  Download
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="mt-8 bg-white rounded-lg shadow" id="account-deletion-panel">
          <div class="px-6 py-6 border-b border-gray-200">
            <h2 class="text-xl font-semibold text-gray-900">Delete Account</h2>
            <p class="mt-1 text-sm text-gray-500">
              Delete sign-in access and anonymize personal account identifiers while preserving event history.
            </p>
          </div>

          <div class="px-6 py-6">
            <.form for={@deletion_form} id="account-deletion-form" phx-submit="delete_account">
              <div class="space-y-4">
                <.input
                  field={@deletion_form[:confirmation]}
                  type="text"
                  label="Type DELETE to confirm"
                  autocomplete="off"
                />

                <div class="flex flex-col gap-3 sm:flex-row">
                  <button
                    id="delete-account-submit"
                    type="submit"
                    class="inline-flex items-center justify-center rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-red-700"
                  >
                    Delete Account
                  </button>
                  <.link
                    id="delete-account-cancel"
                    navigate={~p"/events"}
                    class="inline-flex items-center justify-center rounded-lg bg-gray-200 px-4 py-2 text-sm font-medium text-gray-700 transition-colors hover:bg-gray-300"
                  >
                    Cancel
                  </.link>
                </div>
              </div>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @spec assign_exports(Phoenix.LiveView.Socket.t(), Platser.Accounts.User.t()) ::
          Phoenix.LiveView.Socket.t()
  defp assign_exports(socket, current_user) do
    exports =
      case Privacy.list_account_exports(actor: current_user) do
        {:ok, exports} -> exports
        {:error, _reason} -> []
      end

    assign(socket, exports: exports)
  end

  @spec maybe_schedule_export_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp maybe_schedule_export_refresh(socket) do
    if connected?(socket) and Enum.any?(socket.assigns.exports, &export_active?/1) do
      Process.send_after(self(), :refresh_exports, 2_000)
    end

    socket
  end

  @spec export_active?(Platser.Privacy.Export.t()) :: boolean()
  defp export_active?(export), do: export.status in [:pending, :processing]

  @spec load_current_user(Platser.Accounts.User.t()) :: Platser.Accounts.User.t()
  defp load_current_user(current_user) do
    case Ash.get(Platser.Accounts.User, current_user.id, actor: current_user) do
      {:ok, user} -> user
      {:error, _reason} -> current_user
    end
  end

  @spec downloadable?(Platser.Privacy.Export.t()) :: boolean()
  defp downloadable?(export) do
    export.status == :completed and
      DateTime.compare(export.expires_at, DateTime.utc_now(:second)) == :gt
  end

  @spec format_status(Platser.Privacy.Export.t()) :: String.t()
  defp format_status(export) do
    export.status
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  @spec format_datetime(DateTime.t() | nil) :: String.t()
  defp format_datetime(nil), do: "not available"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end
end
