defmodule PlatserWeb.Events.DashboardLive do
  use PlatserWeb, :live_view

  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.Membership
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Geofence
  alias Platser.Map.Poi

  @impl Phoenix.LiveView
  def mount(%{"id" => event_id}, _session, socket) do
    actor = socket.assigns.current_user

    case load_event(event_id, actor) do
      {:ok, event} ->
        memberships = load_memberships(event_id, actor)
        pois = load_pois(event_id, actor)
        geofences = load_geofences(event_id, actor)
        is_admin = admin?(memberships, actor.id)

        socket =
          socket
          |> assign(:page_title, event.name)
          |> assign(:event, event)
          |> assign(:is_admin, is_admin)
          |> stream(:memberships, memberships)
          |> stream(:pois, pois)
          |> stream(:geofences, geofences)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found or you are not a member.")
         |> push_navigate(to: ~p"/events")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("regenerate_code", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    case Events.regenerate_event_join_code(event, actor: actor) do
      {:ok, updated_event} ->
        {:noreply,
         socket
         |> assign(:event, updated_event)
         |> put_flash(:info, "Join code regenerated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not regenerate join code.")}
    end
  end

  def handle_event("delete_poi", %{"id" => poi_id}, socket) do
    actor = socket.assigns.current_user

    case Ash.get(Poi, poi_id, actor: actor) do
      {:ok, poi} ->
        case PlatserMap.delete_poi(poi, actor: actor) do
          :ok ->
            Phoenix.PubSub.broadcast(
              Platser.PubSub,
              "event:#{socket.assigns.event.id}:map_objects",
              {:poi_removed, poi_id}
            )

            {:noreply, stream_delete(socket, :pois, poi)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete POI.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "POI not found.")}
    end
  end

  def handle_event("delete_geofence", %{"id" => geofence_id}, socket) do
    actor = socket.assigns.current_user

    case Ash.get(Geofence, geofence_id, actor: actor) do
      {:ok, geofence} ->
        case PlatserMap.delete_geofence(geofence, actor: actor) do
          :ok ->
            Phoenix.PubSub.broadcast(
              Platser.PubSub,
              "event:#{socket.assigns.event.id}:map_objects",
              {:geofence_removed, geofence_id}
            )

            {:noreply, stream_delete(socket, :geofences, geofence)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete geofence.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Geofence not found.")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user}>
      <div class="space-y-8">
        <%!-- Page header --%>
        <div class="flex items-start justify-between gap-4 flex-wrap">
          <div>
            <.link
              navigate={~p"/events"}
              class="inline-flex items-center gap-1.5 text-sm text-base-content/60 hover:text-base-content transition-colors mb-3"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" /> All events
            </.link>
            <h1 class="text-2xl font-bold text-base-content">{@event.name}</h1>
            <%= if @event.description do %>
              <p class="mt-1 text-base-content/60 max-w-xl">{@event.description}</p>
            <% end %>
            <div class="mt-2 flex items-center gap-1.5 text-sm text-base-content/50">
              <.icon name="hero-calendar" class="w-4 h-4 shrink-0" />
              <span>
                {Calendar.strftime(@event.starts_at, "%b %-d, %Y %H:%M")}
                <span class="mx-1">–</span>
                {Calendar.strftime(@event.ends_at, "%b %-d, %Y %H:%M")} UTC
              </span>
            </div>
          </div>
          <.link
            navigate={~p"/events/#{@event.id}/map"}
            class="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold hover:brightness-110 active:scale-95 transition-all"
          >
            <.icon name="hero-map" class="w-4 h-4" /> Open Map
          </.link>
        </div>

        <%!-- Join code card --%>
        <section
          id="join-code-section"
          class="bg-base-100 border border-base-200 rounded-2xl p-6 space-y-3"
        >
          <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider">
            Invite Code
          </h2>
          <div class="flex items-center gap-3">
            <div
              id="join-code-display"
              class="flex-1 bg-base-200 rounded-xl px-5 py-3 font-mono text-3xl font-bold tracking-widest text-center text-base-content border border-base-300 select-all"
            >
              {@event.join_code}
            </div>
            <%= if @is_admin do %>
              <button
                id="regenerate-code-btn"
                phx-click="regenerate_code"
                class="p-3 rounded-xl bg-base-100 border border-base-200 hover:bg-base-200 transition-colors text-base-content/60 hover:text-base-content"
                title="Regenerate invite code"
              >
                <.icon name="hero-arrow-path" class="w-5 h-5" />
              </button>
            <% end %>
          </div>
          <p class="text-xs text-base-content/40">
            Share this code with participants. They can join at <strong class="font-medium text-base-content/60">/join/{@event.join_code}</strong>.
            <%= if @is_admin do %>
              Regenerating invalidates the old code; existing members keep access.
            <% end %>
          </p>
        </section>

        <%!-- Members section --%>
        <section id="members-section" class="space-y-4">
          <h2 class="text-lg font-semibold text-base-content">
            Members
          </h2>
          <div
            id="memberships-list"
            phx-update="stream"
            class="bg-base-100 border border-base-200 rounded-2xl divide-y divide-base-200 overflow-hidden"
          >
            <div
              :for={{id, membership} <- @streams.memberships}
              id={id}
              class="flex items-center gap-3 px-5 py-3"
            >
              <div class="w-9 h-9 rounded-full bg-primary/10 flex items-center justify-center shrink-0">
                <span class="text-sm font-bold text-primary uppercase">
                  {String.first(membership.user.display_name)}
                </span>
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-base-content truncate">
                  {membership.user.display_name}
                </p>
                <p class="text-xs text-base-content/40">
                  Joined {Calendar.strftime(membership.joined_at, "%b %-d, %Y")}
                </p>
              </div>
              <span class={[
                "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold shrink-0",
                if(membership.role == :admin,
                  do: "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400",
                  else: "bg-base-200 text-base-content/60"
                )
              ]}>
                {if membership.role == :admin, do: "Admin", else: "Member"}
              </span>
            </div>
          </div>
        </section>

        <%!-- POIs section --%>
        <section id="pois-section" class="space-y-4">
          <h2 class="text-lg font-semibold text-base-content">Points of Interest</h2>
          <div
            id="pois-list"
            phx-update="stream"
            class="bg-base-100 border border-base-200 rounded-2xl divide-y divide-base-200 overflow-hidden"
          >
            <div
              :for={{id, poi} <- @streams.pois}
              id={id}
              class="flex items-center gap-3 px-5 py-3"
            >
              <div class="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center shrink-0">
                <.icon name="hero-map-pin" class="w-4 h-4 text-primary" />
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-base-content truncate">{poi.name}</p>
                <p class="text-xs text-base-content/40 capitalize">{poi.category}</p>
              </div>
              <.visibility_badge visibility={poi.visibility} />
              <%= if @is_admin or poi.creator_id == @current_user.id do %>
                <button
                  id={"delete-poi-#{poi.id}"}
                  phx-click="delete_poi"
                  phx-value-id={poi.id}
                  data-confirm="Delete this POI? This cannot be undone."
                  class="p-1.5 rounded-lg text-base-content/30 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                  title="Delete POI"
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              <% end %>
            </div>
          </div>
          <p
            id="pois-empty"
            class="text-center text-sm text-base-content/40 py-6 bg-base-100 border border-base-200 rounded-2xl hidden only:block"
          >
            No POIs yet. Add some from the map view.
          </p>
        </section>

        <%!-- Geofences section --%>
        <section id="geofences-section" class="space-y-4">
          <h2 class="text-lg font-semibold text-base-content">Geofences</h2>
          <div
            id="geofences-list"
            phx-update="stream"
            class="bg-base-100 border border-base-200 rounded-2xl divide-y divide-base-200 overflow-hidden"
          >
            <div
              :for={{id, geofence} <- @streams.geofences}
              id={id}
              class="flex items-center gap-3 px-5 py-3"
            >
              <div
                class="w-8 h-8 rounded-full flex items-center justify-center shrink-0"
                style={"background-color: #{geofence.color}22;"}
              >
                <span class="w-4 h-4 rounded-sm" style={"background-color: #{geofence.color};"} />
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-base-content truncate">{geofence.name}</p>
                <p class="text-xs text-base-content/40 capitalize">{geofence.purpose}</p>
              </div>
              <.visibility_badge visibility={geofence.visibility} />
              <%= if @is_admin or geofence.creator_id == @current_user.id do %>
                <button
                  id={"delete-geofence-#{geofence.id}"}
                  phx-click="delete_geofence"
                  phx-value-id={geofence.id}
                  data-confirm="Delete this geofence? This cannot be undone."
                  class="p-1.5 rounded-lg text-base-content/30 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                  title="Delete geofence"
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              <% end %>
            </div>
          </div>
          <p
            id="geofences-empty"
            class="text-center text-sm text-base-content/40 py-6 bg-base-100 border border-base-200 rounded-2xl hidden only:block"
          >
            No geofences yet. Draw some from the map view.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :visibility, :atom, required: true

  defp visibility_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium shrink-0",
      if(@visibility == :public,
        do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
        else: "bg-base-200 text-base-content/50"
      )
    ]}>
      <.icon
        name={if @visibility == :public, do: "hero-eye", else: "hero-eye-slash"}
        class="w-3 h-3"
      />
      {if @visibility == :public, do: "Public", else: "Private"}
    </span>
    """
  end

  @spec load_event(Ecto.UUID.t(), Platser.Accounts.User.t()) ::
          {:ok, Event.t()} | {:error, :not_found}
  defp load_event(event_id, actor) do
    case Ash.get(Event, event_id, actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, event} -> {:ok, event}
      {:error, _} -> {:error, :not_found}
    end
  end

  @spec load_memberships(Ecto.UUID.t(), Platser.Accounts.User.t()) :: [Membership.t()]
  defp load_memberships(event_id, actor) do
    case Events.list_memberships_for_event(event_id, actor: actor) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  @spec load_pois(Ecto.UUID.t(), Platser.Accounts.User.t()) :: [Poi.t()]
  defp load_pois(event_id, actor) do
    case PlatserMap.list_pois_for_event(event_id, actor: actor) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  @spec load_geofences(Ecto.UUID.t(), Platser.Accounts.User.t()) :: [Geofence.t()]
  defp load_geofences(event_id, actor) do
    case PlatserMap.list_geofences_for_event(event_id, actor: actor) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  @spec admin?([Membership.t()], Ecto.UUID.t()) :: boolean()
  defp admin?(memberships, user_id) do
    Enum.any?(memberships, &(&1.user_id == user_id and &1.role == :admin))
  end
end
