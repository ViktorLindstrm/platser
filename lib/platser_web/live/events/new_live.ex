defmodule PlatserWeb.Events.NewLive do
  use PlatserWeb, :live_view

  alias Platser.Events.Event

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_create(Event, :create,
        actor: actor,
        as: "event",
        domain: Platser.Events
      )

    socket =
      socket
      |> assign(:page_title, "New Event")
      |> assign(:form, to_form(form))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"event" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  def handle_event("save", %{"event" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event created!")
         |> push_navigate(to: ~p"/events/#{event.id}/dashboard")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user}>
      <div class="max-w-xl mx-auto space-y-6">
        <%!-- Header --%>
        <div>
          <.link
            navigate={~p"/events"}
            class="inline-flex items-center gap-1.5 text-sm text-base-content/60 hover:text-base-content transition-colors mb-4"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to events
          </.link>
          <h1 class="text-2xl font-bold text-base-content">Create New Event</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Set up a new collaborative map event.
          </p>
        </div>

        <%!-- Form card --%>
        <div class="bg-base-100 border border-base-200 rounded-2xl p-6 shadow-sm">
          <.form
            for={@form}
            id="event-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Event name"
              placeholder="e.g. Weekend Hike"
              required
              class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100 text-base-content placeholder:text-base-content/30 focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary transition"
            />

            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              placeholder="Optional — describe the event for participants."
              class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100 text-base-content placeholder:text-base-content/30 focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary transition resize-none"
              rows="3"
            />

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:starts_at]}
                type="datetime-local"
                label="Starts at (UTC)"
                required
                class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary transition"
              />
              <.input
                field={@form[:ends_at]}
                type="datetime-local"
                label="Ends at (UTC)"
                required
                class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary transition"
              />
            </div>

            <p class="text-xs text-base-content/40">
              Times are in UTC. An invite code will be generated automatically after creation.
            </p>

            <div class="flex items-center gap-3 pt-2">
              <button
                type="submit"
                id="submit-btn"
                class="flex-1 py-2.5 px-6 rounded-xl bg-primary text-primary-content font-semibold text-sm hover:brightness-110 active:scale-95 transition-all"
              >
                Create Event
              </button>
              <.link
                navigate={~p"/events"}
                class="py-2.5 px-6 rounded-xl bg-base-200 text-base-content/70 font-semibold text-sm hover:bg-base-300 transition-colors"
              >
                Cancel
              </.link>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
