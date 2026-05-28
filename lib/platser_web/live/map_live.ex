defmodule PlatserWeb.MapLive do
  use PlatserWeb, :live_view

  alias Platser.Activity
  alias Platser.Activity.Entry
  alias Platser.Events.Event
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Geofence
  alias Platser.Map.Poi

  @pmtiles_url Application.compile_env(
                 :platser,
                 :pmtiles_url,
                 "pmtiles://https://r2-public.protomaps.com/protomaps-sample-datasets/nz.pmtiles"
               )

  @type map_object_msg ::
          {:poi_added, Poi.t()}
          | {:poi_updated, Poi.t()}
          | {:poi_removed, Ecto.UUID.t()}
          | {:geofence_added, Geofence.t()}
          | {:geofence_updated, Geofence.t()}
          | {:geofence_removed, Ecto.UUID.t()}

  @type activity_msg :: {:entry_added, Entry.t()}

  @impl Phoenix.LiveView
  def mount(%{"event_id" => event_id}, _session, socket) do
    actor = socket.assigns.current_user

    case load_event(event_id, actor) do
      {:ok, event} ->
        {pois, geofences, entries} = load_map_data(event_id, actor)

        socket =
          socket
          |> assign(:event, event)
          |> assign(:pois, pois)
          |> assign(:geofences, geofences)
          |> assign(:entries, entries)
          |> assign(:unread_count, 0)
          |> assign(:drawer_open, false)
          |> assign(:pmtiles_url, @pmtiles_url)

        socket =
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event_id}:map_objects")
            Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event_id}:activity")
            send(self(), :push_map_init)
            socket
          else
            socket
          end

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found or you are not a member.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:push_map_init, socket) do
    payload = %{
      pois: to_geojson_feature_collection(socket.assigns.pois, &poi_to_feature/1),
      geofences: to_geojson_feature_collection(socket.assigns.geofences, &geofence_to_feature/1)
    }

    {:noreply, push_event(socket, "map_init", payload)}
  end

  def handle_info({:poi_added, poi}, socket) do
    {:noreply, push_event(socket, "poi_added", poi_to_feature(poi))}
  end

  def handle_info({:poi_updated, poi}, socket) do
    {:noreply, push_event(socket, "poi_updated", poi_to_feature(poi))}
  end

  def handle_info({:poi_removed, poi_id}, socket) do
    {:noreply, push_event(socket, "poi_removed", %{"id" => poi_id})}
  end

  def handle_info({:geofence_added, geofence}, socket) do
    {:noreply, push_event(socket, "geofence_added", geofence_to_feature(geofence))}
  end

  def handle_info({:geofence_updated, geofence}, socket) do
    {:noreply, push_event(socket, "geofence_updated", geofence_to_feature(geofence))}
  end

  def handle_info({:geofence_removed, geofence_id}, socket) do
    {:noreply, push_event(socket, "geofence_removed", %{"id" => geofence_id})}
  end

  def handle_info({:entry_added, entry}, socket) do
    {:noreply,
     socket
     |> update(:entries, fn entries -> [entry | Enum.take(entries, 49)] end)
     |> update(:unread_count, fn count ->
       if socket.assigns.drawer_open, do: count, else: count + 1
     end)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_drawer", _params, socket) do
    drawer_open = !socket.assigns.drawer_open

    {:noreply,
     socket
     |> assign(:drawer_open, drawer_open)
     |> assign(:unread_count, if(drawer_open, do: 0, else: socket.assigns.unread_count))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Full-viewport map canvas --%>
      <div
        id="map-canvas"
        class="fixed inset-0 z-10"
        phx-hook="Map"
        phx-update="ignore"
        data-pmtiles-url={@pmtiles_url}
        data-map-center="-36.8485,174.7633"
        data-map-zoom="12"
        data-map-flavor="light"
      />

      <%!-- Top bar: event name --%>
      <div class="fixed top-0 left-0 right-0 z-20 pointer-events-none">
        <div class="flex items-center justify-between px-4 pt-4">
          <div class="bg-base-100/90 backdrop-blur-sm rounded-xl px-4 py-2 shadow-lg border border-base-300 pointer-events-auto">
            <h1 class="text-sm font-semibold text-base-content truncate max-w-[60vw]">
              {@event.name}
            </h1>
          </div>
          <.link
            navigate={~p"/join/#{@event.join_code}"}
            class="bg-base-100/90 backdrop-blur-sm rounded-xl px-3 py-2 shadow-lg border border-base-300 pointer-events-auto"
          >
            <.icon name="hero-users" class="w-4 h-4 text-base-content/70" />
          </.link>
        </div>
      </div>

      <%!-- Floating action buttons (bottom-right) --%>
      <div class="fixed bottom-24 right-4 z-20 flex flex-col gap-3">
        <button
          id="add-geofence-btn"
          class="w-12 h-12 bg-base-100/90 backdrop-blur-sm rounded-full shadow-lg border border-base-300 flex items-center justify-center hover:bg-base-200 active:scale-95 transition-all"
          title="Draw geofence (coming soon)"
          disabled
        >
          <.icon name="hero-map" class="w-5 h-5 text-base-content/60" />
        </button>
        <button
          id="add-poi-btn"
          class="w-12 h-12 bg-primary rounded-full shadow-lg flex items-center justify-center hover:brightness-110 active:scale-95 transition-all"
          title="Add point of interest (coming soon)"
          disabled
        >
          <.icon name="hero-map-pin" class="w-5 h-5 text-primary-content" />
        </button>
      </div>

      <%!-- Activity feed drawer --%>
      <div
        id="activity-drawer"
        class={[
          "fixed bottom-0 left-0 right-0 z-20 transform transition-transform duration-300 ease-in-out",
          if(not @drawer_open, do: "translate-y-[calc(100%-3.5rem)]")
        ]}
      >
        <div class="bg-base-100 rounded-t-2xl border-t border-base-300 shadow-2xl">
          <%!-- Drawer handle / toggle button --%>
          <button
            id="drawer-toggle"
            phx-click="toggle_drawer"
            class="w-full py-3 flex flex-col items-center gap-1 focus:outline-none"
          >
            <div class="w-10 h-1 bg-base-300 rounded-full" />
            <div class="flex items-center gap-2">
              <.icon name="hero-bell" class="w-4 h-4 text-base-content/60" />
              <span class="text-xs font-medium text-base-content/60">Activity</span>
              <%= if @unread_count > 0 do %>
                <span class="inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-primary-content bg-primary rounded-full">
                  {if @unread_count > 9, do: "9+", else: @unread_count}
                </span>
              <% end %>
            </div>
          </button>

          <%!-- Feed entries --%>
          <div id="activity-entries" class="px-4 pb-6 max-h-72 overflow-y-auto space-y-2">
            <%= if Enum.empty?(@entries) do %>
              <p class="text-center text-sm text-base-content/40 py-4">
                No activity yet. Start exploring!
              </p>
            <% end %>
            <%= for entry <- @entries do %>
              <div class="flex items-start gap-3 py-2 border-b border-base-200 last:border-0">
                <div class="w-8 h-8 bg-primary/10 rounded-full flex items-center justify-center shrink-0 mt-0.5">
                  <.icon name={entry_icon(entry.action)} class="w-4 h-4 text-primary" />
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm text-base-content leading-snug">{entry.message}</p>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    {Calendar.strftime(entry.inserted_at, "%H:%M")}
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
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

  @spec load_map_data(Ecto.UUID.t(), Platser.Accounts.User.t()) ::
          {[Poi.t()], [Geofence.t()], [Entry.t()]}
  defp load_map_data(event_id, actor) do
    pois =
      case PlatserMap.list_pois_for_event(event_id, actor: actor) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    geofences =
      case PlatserMap.list_geofences_for_event(event_id, actor: actor) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    entries =
      case Activity.list_entries_for_event(event_id, actor: actor) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    {pois, geofences, entries}
  end

  @spec to_geojson_feature_collection([struct()], (struct() -> map())) :: map()
  defp to_geojson_feature_collection(records, to_feature_fn) do
    %{"type" => "FeatureCollection", "features" => Enum.map(records, to_feature_fn)}
  end

  @spec poi_to_feature(Poi.t()) :: map()
  defp poi_to_feature(%Poi{} = poi) do
    %{
      "type" => "Feature",
      "id" => poi.id,
      "geometry" => Geo.JSON.encode!(poi.location),
      "properties" => %{
        "id" => poi.id,
        "name" => poi.name,
        "category" => to_string(poi.category),
        "description" => poi.description
      }
    }
  end

  @spec geofence_to_feature(Geofence.t()) :: map()
  defp geofence_to_feature(%Geofence{} = geofence) do
    %{
      "type" => "Feature",
      "id" => geofence.id,
      "geometry" => Geo.JSON.encode!(geofence.geometry),
      "properties" => %{
        "id" => geofence.id,
        "name" => geofence.name,
        "purpose" => to_string(geofence.purpose),
        "color" => geofence.color
      }
    }
  end

  @spec entry_icon(atom()) :: String.t()
  defp entry_icon(:poi_published), do: "hero-map-pin"
  defp entry_icon(:geofence_published), do: "hero-map"
  defp entry_icon(:joined_event), do: "hero-user-plus"
  defp entry_icon(:comment_added), do: "hero-chat-bubble-left"
  defp entry_icon(:entered_geofence), do: "hero-arrow-right-circle"
  defp entry_icon(:exited_geofence), do: "hero-arrow-left-circle"
  defp entry_icon(_), do: "hero-bell"
end
