defmodule PlatserWeb.Events.IndexLive do
  use PlatserWeb, :live_view

  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.Membership

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    events =
      case Events.list_events_for_user(actor: actor) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    socket =
      socket
      |> assign(:page_title, "My Events")
      |> assign(:join_code_valid, false)
      |> stream(:events, events)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate_join_code", %{"code" => code}, socket) when is_binary(code) do
    is_valid = String.length(code) == 6 && code =~ ~r/^[A-Za-z0-9]{6}$/
    {:noreply, assign(socket, :join_code_valid, is_valid)}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("join_by_code", %{"code" => code}, socket) when is_binary(code) do
    code_upper = String.upcase(code)
    {:noreply, push_navigate(socket, to: ~p"/join/#{code_upper}")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user}>
      <div class="space-y-8">
        <%!-- Page header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">My Events</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Events you've created or joined.
            </p>
          </div>
          <.link
            navigate={~p"/events/new"}
            id="create-event-btn"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-primary text-primary-content text-sm font-semibold hover:brightness-110 active:scale-95 transition-all"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> New Event
          </.link>
        </div>

        <%!-- Join an event form --%>
        <div class="bg-base-100 border border-base-200 rounded-2xl p-6">
          <h2 class="font-semibold text-base-content mb-4">Join an Event</h2>
          <p class="text-sm text-base-content/60 mb-4">
            Have an invite code? Enter it here to join an event.
          </p>
          <form phx-submit="join_by_code" class="flex flex-col sm:flex-row gap-2">
            <input
              type="text"
              name="code"
              maxlength="6"
              placeholder="Enter code (e.g., AX7K2P)"
              class="flex-1 px-4 py-3 rounded-xl border border-base-300 bg-base-100 text-base-content placeholder:text-base-content/40 focus:outline-none focus:border-primary focus:ring-1 focus:ring-primary"
              id="join-code-input"
              phx-change="validate_join_code"
            />
            <button
              type="submit"
              id="join-code-btn"
              disabled={@join_code_valid == false}
              class={[
                "px-6 py-3 rounded-xl font-medium transition-all whitespace-nowrap",
                if(@join_code_valid == true,
                  do: "bg-primary text-primary-content hover:brightness-110 active:scale-95",
                  else: "bg-base-300 text-base-content/50 cursor-not-allowed"
                )
              ]}
            >
              Join
            </button>
          </form>
        </div>

        <%!-- Event list --%>
        <div id="events-list" phx-update="stream" class="grid gap-4 sm:grid-cols-2">
          <div :for={{id, event} <- @streams.events} id={id}>
            <.event_card event={event} current_user={@current_user} />
          </div>
        </div>

        <%!-- Empty state --%>
        <div
          id="events-empty"
          class={[
            "text-center py-20 space-y-4",
            "hidden only:block"
          ]}
        >
          <div class="w-16 h-16 bg-base-200 rounded-full flex items-center justify-center mx-auto">
            <.icon name="hero-map" class="w-8 h-8 text-base-content/30" />
          </div>
          <div>
            <p class="text-base-content/60 font-medium">No events yet</p>
            <p class="text-sm text-base-content/40 mt-1">
              Create your first event or join one with an invite code.
            </p>
          </div>
          <.link
            navigate={~p"/events/new"}
            class="inline-flex items-center gap-2 px-5 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold hover:brightness-110 active:scale-95 transition-all"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Create Event
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :event, Event, required: true
  attr :current_user, :map, required: true

  defp event_card(assigns) do
    assigns =
      assign(assigns, :my_role, find_role(assigns.event.memberships, assigns.current_user.id))

    ~H"""
    <div class="group bg-base-100 border border-base-200 rounded-2xl p-5 hover:border-primary/30 hover:shadow-md transition-all space-y-4">
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <h2 class="font-semibold text-base-content truncate">{@event.name}</h2>
          <%= if @event.description do %>
            <p class="mt-0.5 text-sm text-base-content/60 line-clamp-2">{@event.description}</p>
          <% end %>
        </div>
        <span class={[
          "shrink-0 inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-semibold",
          if(@my_role == :admin,
            do: "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400",
            else: "bg-base-200 text-base-content/70"
          )
        ]}>
          {if @my_role == :admin, do: "Admin", else: "Member"}
        </span>
      </div>

      <div class="flex items-center gap-1.5 text-xs text-base-content/50">
        <.icon name="hero-calendar" class="w-3.5 h-3.5 shrink-0" />
        <span>
          {Calendar.strftime(@event.starts_at, "%b %-d, %Y %H:%M")}
          <span class="mx-1">–</span>
          {Calendar.strftime(@event.ends_at, "%b %-d, %Y %H:%M")}
        </span>
        <span class="ml-1 text-base-content/30">(UTC)</span>
      </div>

      <div class="flex items-center gap-2 pt-1 border-t border-base-200">
        <.link
          navigate={~p"/events/#{@event.id}/map"}
          class="flex-1 flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-medium bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
        >
          <.icon name="hero-map" class="w-3.5 h-3.5" /> Open Map
        </.link>
        <.link
          navigate={~p"/events/#{@event.id}/dashboard"}
          class="flex-1 flex items-center justify-center gap-1.5 py-2 rounded-xl text-xs font-medium bg-base-200 text-base-content/70 hover:bg-base-300 transition-colors"
        >
          <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" /> Manage
        </.link>
      </div>
    </div>
    """
  end

  @spec find_role([Membership.t()], Ecto.UUID.t()) :: :admin | :member
  defp find_role(memberships, user_id) do
    case Enum.find(memberships, &(&1.user_id == user_id)) do
      %Membership{role: role} -> role
      nil -> :member
    end
  end
end
