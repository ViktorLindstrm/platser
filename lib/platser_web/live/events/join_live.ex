defmodule PlatserWeb.Events.JoinLive do
  use PlatserWeb, :live_view

  require Ash.Query

  alias Platser.Events
  alias Platser.Events.Membership

  @type join_status :: :show | :already_member | :manager | :not_found | :joined | :guest_form

  @impl Phoenix.LiveView
  def mount(%{"code" => code}, _session, socket) do
    actor = socket.assigns.current_user
    socket = load_event(socket, code, actor)
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("join", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    case Events.join_event(event.join_code, actor: actor) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> assign(:membership, membership)
         |> assign(:status, :joined)}

      {:error, error} ->
        message = format_error(error)
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("regenerate_code", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    case Events.regenerate_event_join_code(event, actor: actor) do
      {:ok, updated_event} ->
        {:noreply,
         socket
         |> assign(:event, updated_event)
         |> put_flash(:info, "Join code regenerated")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not regenerate join code")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user}>
      <div class="min-h-screen flex items-center justify-center px-4">
        <%= cond do %>
          <% @status == :not_found -> %>
            <div id="invalid-invite-panel" class="max-w-md w-full text-center space-y-6">
              <div class="w-16 h-16 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto">
                <.icon name="hero-x-mark" class="w-8 h-8 text-red-500" />
              </div>
              <div>
                <h1 class="text-2xl font-bold text-base-content">Invalid Invite</h1>
                <p class="mt-2 text-base-content/60">
                  This invite link is invalid or has expired. Ask the event organiser for a new one.
                </p>
              </div>
              <.link
                navigate={~p"/"}
                class="inline-flex items-center gap-2 text-sm text-primary hover:underline"
              >
                <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to home
              </.link>
            </div>
          <% @status == :already_member -> %>
            <div id="already-member-panel" class="max-w-md w-full space-y-6">
              <div class="bg-base-200 rounded-2xl p-8 text-center space-y-4">
                <div class="w-16 h-16 bg-green-100 dark:bg-green-900/30 rounded-full flex items-center justify-center mx-auto">
                  <.icon name="hero-check" class="w-8 h-8 text-green-500" />
                </div>
                <h1 class="text-2xl font-bold text-base-content">{@event.name}</h1>
                <p class="text-base-content/60">You're already a member of this event.</p>
                <div class="text-sm text-base-content/50">
                  {@event.starts_at |> Calendar.strftime("%b %-d, %Y at %H:%M")}
                </div>
                <.link
                  navigate={~p"/events/#{@event.id}/map"}
                  class="inline-flex items-center gap-2 w-full justify-center py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
                >
                  <.icon name="hero-map" class="w-5 h-5" /> Open Map
                </.link>
              </div>
            </div>
          <% @status == :joined -> %>
            <div id="joined-panel" class="max-w-md w-full space-y-6">
              <div class="bg-base-200 rounded-2xl p-8 text-center space-y-4">
                <div class="w-16 h-16 bg-green-100 dark:bg-green-900/30 rounded-full flex items-center justify-center mx-auto animate-bounce">
                  <.icon name="hero-check" class="w-8 h-8 text-green-500" />
                </div>
                <h1 class="text-2xl font-bold text-base-content">You're in!</h1>
                <p class="text-base-content/60">
                  Welcome to <span class="font-semibold text-base-content">{@event.name}</span>.
                </p>
                <div class="text-sm text-base-content/50">
                  {@event.starts_at |> Calendar.strftime("%b %-d, %Y at %H:%M")}
                </div>
                <.link
                  navigate={~p"/events/#{@event.id}/map"}
                  class="inline-flex items-center gap-2 w-full justify-center py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
                >
                  <.icon name="hero-map" class="w-5 h-5" /> Open Map
                </.link>
              </div>
            </div>
          <% @status == :manager -> %>
            <div id="manager-invite-panel" class="max-w-md w-full space-y-6">
              <div class="bg-base-200 rounded-2xl p-8 space-y-6">
                <div>
                  <span class="inline-block text-xs font-semibold uppercase tracking-widest text-primary mb-3">
                    Your Event
                  </span>
                  <h1 class="text-2xl font-bold text-base-content">{@event.name}</h1>
                  <%= if @event.description do %>
                    <p class="mt-2 text-base-content/60">{@event.description}</p>
                  <% end %>
                  <div class="mt-3 text-sm text-base-content/50">
                    <.icon name="hero-calendar" class="w-4 h-4 inline mr-1" />
                    {@event.starts_at |> Calendar.strftime("%b %-d, %Y at %H:%M")} &ndash; {@event.ends_at
                    |> Calendar.strftime("%H:%M")}
                  </div>
                </div>

                <div class="border-t border-base-300 pt-6">
                  <p class="text-sm font-medium text-base-content/70 mb-3">Share invite code</p>
                  <div class="flex items-center gap-3">
                    <div class="flex-1 bg-base-100 rounded-xl px-4 py-3 font-mono text-2xl font-bold tracking-widest text-center text-base-content border border-base-300">
                      {@event.join_code}
                    </div>
                    <button
                      id="regenerate-btn"
                      phx-click="regenerate_code"
                      class="p-3 rounded-xl bg-base-100 border border-base-300 hover:bg-base-300 transition-colors text-base-content/60 hover:text-base-content"
                      title="Regenerate code"
                    >
                      <.icon name="hero-arrow-path" class="w-5 h-5" />
                    </button>
                  </div>
                  <p class="mt-2 text-xs text-base-content/40">
                    Regenerating will invalidate the current code. Existing members keep their access.
                  </p>
                </div>

                <.link
                  navigate={~p"/events/#{@event.id}/map"}
                  class="inline-flex items-center gap-2 w-full justify-center py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
                >
                  <.icon name="hero-map" class="w-5 h-5" /> Open Map
                </.link>
              </div>
            </div>
          <% @status == :guest_form -> %>
            <%!-- Unauthenticated visitor — offer guest join or sign-in --%>
            <div class="max-w-md w-full space-y-6">
              <div class="bg-base-200 rounded-2xl p-8 space-y-6">
                <div>
                  <span class="inline-block text-xs font-semibold uppercase tracking-widest text-primary mb-3">
                    You're invited
                  </span>
                  <h1 class="text-2xl font-bold text-base-content">{@event.name}</h1>
                  <%= if @event.description do %>
                    <p class="mt-2 text-base-content/60">{@event.description}</p>
                  <% end %>
                  <div class="mt-3 text-sm text-base-content/50">
                    <.icon name="hero-calendar" class="w-4 h-4 inline mr-1" />
                    {@event.starts_at |> Calendar.strftime("%b %-d, %Y at %H:%M")} &ndash; {@event.ends_at
                    |> Calendar.strftime("%H:%M")}
                  </div>
                </div>

                <div class="border-t border-base-300 pt-6 space-y-4">
                  <p class="text-sm font-semibold text-base-content">Join as a guest</p>
                  <.form
                    for={%{}}
                    action={~p"/guest-join/#{@event.join_code}"}
                    method="post"
                    id="guest-join-form"
                  >
                    <div class="space-y-3">
                      <input
                        id="display_name"
                        name="display_name"
                        type="text"
                        class="w-full rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all"
                        placeholder="Your name (optional)"
                        autocomplete="nickname"
                      />
                      <button
                        type="submit"
                        id="guest-join-btn"
                        class="w-full py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
                      >
                        Join as Guest
                      </button>
                    </div>
                  </.form>
                </div>

                <div class="border-t border-base-300 pt-4 text-center text-sm text-base-content/50">
                  Already have an account?
                  <.link
                    navigate={~p"/sign-in"}
                    class="text-primary hover:underline font-medium"
                  >
                    Sign in
                  </.link>
                </div>
              </div>
            </div>
          <% true -> %>
            <%!-- :show status — authenticated non-member viewing join page --%>
            <div id="join-invite-panel" class="max-w-md w-full space-y-6">
              <div class="bg-base-200 rounded-2xl p-8 space-y-6">
                <div>
                  <span class="inline-block text-xs font-semibold uppercase tracking-widest text-primary mb-3">
                    You're invited
                  </span>
                  <h1 class="text-2xl font-bold text-base-content">{@event.name}</h1>
                  <%= if @event.description do %>
                    <p class="mt-2 text-base-content/60">{@event.description}</p>
                  <% end %>
                  <div class="mt-3 text-sm text-base-content/50">
                    <.icon name="hero-calendar" class="w-4 h-4 inline mr-1" />
                    {@event.starts_at |> Calendar.strftime("%b %-d, %Y at %H:%M")} &ndash; {@event.ends_at
                    |> Calendar.strftime("%H:%M")}
                  </div>
                </div>

                <button
                  id="join-btn"
                  phx-click="join"
                  class="w-full py-3 px-6 rounded-xl bg-primary text-primary-content font-semibold hover:brightness-110 active:scale-95 transition-all"
                >
                  Join Event
                </button>
              </div>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @spec load_event(Phoenix.LiveView.Socket.t(), String.t(), Platser.Accounts.User.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp load_event(socket, code, nil) do
    case Events.get_event_by_join_code(code, authorize?: false) do
      {:ok, nil} ->
        assign(socket, :status, :not_found)

      {:ok, event} ->
        socket
        |> assign(:event, event)
        |> assign(:membership, nil)
        |> assign(:status, :guest_form)

      {:error, _} ->
        assign(socket, :status, :not_found)
    end
  end

  defp load_event(socket, code, actor) do
    case Events.get_event_by_join_code(code, actor: actor) do
      {:ok, nil} ->
        assign(socket, :status, :not_found)

      {:ok, event} ->
        membership = get_user_membership(event.id, actor.id, actor)

        socket
        |> assign(:event, event)
        |> assign(:membership, membership)
        |> assign(:status, resolve_status(membership))

      {:error, _} ->
        assign(socket, :status, :not_found)
    end
  end

  @spec get_user_membership(Ecto.UUID.t(), Ecto.UUID.t(), Platser.Accounts.User.t()) ::
          Membership.t() | nil
  defp get_user_membership(event_id, user_id, actor) do
    Membership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(event_id == ^event_id and user_id == ^user_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end

  @spec resolve_status(Membership.t() | nil) :: join_status()
  defp resolve_status(nil), do: :show

  defp resolve_status(%Membership{role: role}) when role in [:full_manager, :admin],
    do: :manager

  defp resolve_status(%Membership{}), do: :already_member

  @spec format_error(any()) :: String.t()
  defp format_error(%Ash.Error.Invalid{} = error) do
    error.errors
    |> Enum.map_join(", ", fn e -> Map.get(e, :message, "unknown error") end)
  end

  defp format_error(_), do: "Something went wrong. Please try again."
end
