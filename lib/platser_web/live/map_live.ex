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

  @poi_categories [:viewpoint, :camp, :hazard, :meeting_point, :food, :other]

  @type map_object_msg ::
          {:poi_added, Poi.t()}
          | {:poi_updated, Poi.t()}
          | {:poi_removed, Ecto.UUID.t()}
          | {:geofence_added, Geofence.t()}
          | {:geofence_updated, Geofence.t()}
          | {:geofence_removed, Ecto.UUID.t()}

  @type activity_msg :: {:entry_added, Entry.t()}

  @type poi_step :: :idle | :picking | :editing

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
          |> assign(:poi_step, :idle)
          |> assign(:poi_location, nil)
          |> assign(:poi_name, "")
          |> assign(:poi_description, "")
          |> assign(:poi_category, "viewpoint")
          |> assign(:poi_errors, [])
          |> assign(:poi_categories, @poi_categories)
          |> allow_upload(:photos,
            accept: ~w(.jpg .jpeg .png .webp),
            max_entries: 5,
            max_file_size: 10_000_000
          )

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

  def handle_event("open_poi_form", _params, socket) do
    socket =
      socket
      |> assign(:poi_step, :picking)
      |> assign(:poi_location, nil)
      |> assign(:poi_name, "")
      |> assign(:poi_description, "")
      |> assign(:poi_category, "viewpoint")
      |> assign(:poi_errors, [])
      |> push_event("enable_location_pick", %{})

    {:noreply, socket}
  end

  def handle_event("cancel_poi_form", _params, socket) do
    {:noreply, reset_poi_form(socket)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photos, ref)}
  end

  def handle_event("poi_location_picked", %{"lat" => lat, "lng" => lng}, socket) do
    location = %Geo.Point{coordinates: {lng, lat}, srid: 4326}

    {:noreply,
     socket
     |> assign(:poi_step, :editing)
     |> assign(:poi_location, location)
     |> push_event("disable_location_pick", %{})}
  end

  def handle_event("pick_location_again", _params, socket) do
    {:noreply,
     socket
     |> assign(:poi_step, :picking)
     |> assign(:poi_location, nil)
     |> push_event("enable_location_pick", %{})}
  end

  def handle_event("validate_poi", %{"poi" => params}, socket) do
    {:noreply,
     socket
     |> assign(:poi_name, params["name"] || "")
     |> assign(:poi_description, params["description"] || "")
     |> assign(:poi_category, params["category"] || "viewpoint")}
  end

  def handle_event("save_poi", %{"poi" => params} = event_params, socket) do
    publish? = Map.get(event_params, "publish") == "true"
    submit_poi(params, publish?, socket)
  end

  @spec submit_poi(map(), boolean(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp submit_poi(params, publish?, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event
    location = socket.assigns.poi_location

    errors = validate_poi_params(params, location)

    if errors != [] do
      {:noreply, assign(socket, :poi_errors, errors)}
    else
      poi_params = %{
        name: String.trim(params["name"]),
        description: params["description"],
        category: String.to_existing_atom(params["category"]),
        location: location,
        event_id: event.id
      }

      case PlatserMap.create_poi(poi_params, actor: actor) do
        {:ok, poi} ->
          _uploaded_paths = handle_photo_uploads(socket, poi, actor)

          socket =
            if publish? do
              case PlatserMap.publish_poi(poi, actor: actor) do
                {:ok, _published} ->
                  socket
                  |> reset_poi_form()
                  |> push_event("poi_added", poi_to_feature(poi))
                  |> put_flash(:info, "POI published! Everyone can see it.")

                {:error, %Ash.Error.Invalid{} = err} ->
                  msg = Ash.Error.to_error_class(err).message || "Could not publish POI"
                  socket |> reset_poi_form() |> put_flash(:error, msg)

                {:error, _} ->
                  socket |> reset_poi_form() |> put_flash(:error, "Could not publish POI")
              end
            else
              socket
              |> reset_poi_form()
              |> push_event("poi_added", poi_to_feature(poi))
              |> put_flash(:info, "POI saved as draft. Only you can see it.")
            end

          {:noreply, socket}

        {:error, %Ash.Error.Invalid{} = err} ->
          errors = format_ash_errors(err)
          {:noreply, assign(socket, :poi_errors, errors)}

        {:error, _} ->
          {:noreply, assign(socket, :poi_errors, [{"base", "Could not save POI"}])}
      end
    end
  end

  @spec validate_poi_params(map(), Geo.Point.t() | nil) :: [{String.t(), String.t()}]
  defp validate_poi_params(params, location) do
    []
    |> then(fn errs ->
      name = String.trim(params["name"] || "")
      if name == "", do: [{"name", "can't be blank"} | errs], else: errs
    end)
    |> then(fn errs ->
      if is_nil(location), do: [{"location", "tap the map to set a location"} | errs], else: errs
    end)
  end

  @spec handle_photo_uploads(
          Phoenix.LiveView.Socket.t(),
          Poi.t(),
          Platser.Accounts.User.t()
        ) :: [String.t()]
  defp handle_photo_uploads(socket, poi, actor) do
    dir = uploads_dir_for(poi.id)
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :photos, fn %{path: tmp_path}, entry ->
      stored_filename = "#{Ecto.UUID.generate()}_#{Path.basename(entry.client_name)}"
      dest = Path.join(dir, stored_filename)

      case File.cp(tmp_path, dest) do
        :ok ->
          url_path = "/uploads/#{poi.id}/#{stored_filename}"

          Platser.Media.create_attachment(
            %{
              filename: entry.client_name,
              stored_filename: stored_filename,
              content_type: entry.client_type,
              path: url_path,
              poi_id: poi.id
            },
            actor: actor,
            authorize?: false
          )

          {:ok, url_path}

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to copy upload #{entry.client_name}: #{inspect(reason)}")
          {:ok, nil}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec uploads_dir_for(Ecto.UUID.t()) :: String.t()
  defp uploads_dir_for(poi_id) do
    Application.app_dir(:platser, "priv/static/uploads/#{poi_id}")
  end

  @spec format_ash_errors(Ash.Error.Invalid.t()) :: [{String.t(), String.t()}]
  defp format_ash_errors(%Ash.Error.Invalid{errors: errors}) do
    Enum.map(errors, fn
      %{field: field, message: msg} when not is_nil(field) ->
        {to_string(field), msg}

      %{message: msg} ->
        {"base", msg}

      err ->
        {"base", inspect(err)}
    end)
  end

  @spec reset_poi_form(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_poi_form(socket) do
    socket
    |> assign(:poi_step, :idle)
    |> assign(:poi_location, nil)
    |> assign(:poi_name, "")
    |> assign(:poi_description, "")
    |> assign(:poi_category, "viewpoint")
    |> assign(:poi_errors, [])
    |> push_event("disable_location_pick", %{})
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Full-viewport map canvas --%>
      <div id="map-wrapper" style="position: fixed; inset: 0; z-index: 10;">
        <div
          id="map-canvas"
          style="width: 100%; height: 100%;"
          phx-hook="Map"
          phx-update="ignore"
          data-pmtiles-url={@pmtiles_url}
          data-map-center="-36.8485,174.7633"
          data-map-zoom="12"
          data-map-flavor="light"
        />
      </div>

      <%!-- Top bar: event name --%>
      <div class="fixed top-0 left-0 right-0 z-20 pointer-events-none">
        <div class="flex items-center justify-between px-4 pt-4">
          <div class="bg-white/90 backdrop-blur-sm rounded-xl px-4 py-2 shadow-lg border border-gray-200 pointer-events-auto">
            <h1 class="text-sm font-semibold text-gray-900 truncate max-w-[60vw]">
              {@event.name}
            </h1>
          </div>
          <.link
            navigate={~p"/join/#{@event.join_code}"}
            class="bg-white/90 backdrop-blur-sm rounded-xl px-3 py-2 shadow-lg border border-gray-200 pointer-events-auto"
          >
            <.icon name="hero-users" class="w-4 h-4 text-gray-500" />
          </.link>
        </div>
      </div>

      <%!-- Location pick overlay --%>
      <%= if @poi_step == :picking do %>
        <div class="fixed top-16 left-0 right-0 z-30 flex justify-center pointer-events-none">
          <div class="bg-gray-900/90 backdrop-blur-sm text-white text-sm font-medium px-5 py-2.5 rounded-full shadow-xl flex items-center gap-2 pointer-events-auto">
            <.icon name="hero-map-pin" class="w-4 h-4 text-blue-400 animate-pulse" />
            Tap the map to place your POI
            <button
              phx-click="cancel_poi_form"
              class="ml-2 text-gray-400 hover:text-white transition-colors"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>
      <% end %>

      <%!-- Floating action buttons (bottom-right) --%>
      <div class={[
        "fixed bottom-24 right-4 z-20 flex flex-col gap-3 transition-all duration-300",
        @poi_step != :idle && "opacity-0 pointer-events-none"
      ]}>
        <button
          id="add-geofence-btn"
          class="w-12 h-12 bg-white/90 backdrop-blur-sm rounded-full shadow-lg border border-gray-200 flex items-center justify-center hover:bg-gray-100 active:scale-95 transition-all"
          title="Draw geofence (coming soon)"
          disabled
        >
          <.icon name="hero-map" class="w-5 h-5 text-gray-400" />
        </button>
        <button
          id="add-poi-btn"
          phx-click="open_poi_form"
          class="w-12 h-12 bg-blue-600 rounded-full shadow-lg flex items-center justify-center hover:bg-blue-700 active:scale-95 transition-all"
          title="Add point of interest"
        >
          <.icon name="hero-map-pin" class="w-5 h-5 text-white" />
        </button>
      </div>

      <%!-- POI creation form (bottom sheet) --%>
      <div
        id="poi-form-sheet"
        class={[
          "fixed inset-x-0 bottom-0 z-30 transform transition-transform duration-300 ease-out",
          if(@poi_step == :editing, do: "translate-y-0", else: "translate-y-full")
        ]}
      >
        <div class="bg-white rounded-t-2xl border-t border-gray-200 shadow-2xl max-h-[85vh] flex flex-col">
          <%!-- Sheet header --%>
          <div class="flex items-center justify-between px-5 pt-4 pb-3 border-b border-gray-100">
            <div class="w-10 h-1 bg-gray-200 rounded-full absolute top-2 left-1/2 -translate-x-1/2" />
            <h2 class="text-base font-semibold text-gray-900">New Point of Interest</h2>
            <button
              phx-click="cancel_poi_form"
              class="w-8 h-8 flex items-center justify-center rounded-full hover:bg-gray-100 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-4 h-4 text-gray-500" />
            </button>
          </div>

          <%!-- Form body --%>
          <div class="flex-1 overflow-y-auto">
            <.form
              for={%{}}
              id="poi-form"
              phx-change="validate_poi"
              phx-submit="save_poi"
              class="px-5 py-4 space-y-4"
            >
              <%!-- Location indicator --%>
              <div class="flex items-center gap-2">
                <div class={[
                  "flex-1 flex items-center gap-2 px-3 py-2 rounded-xl border text-sm",
                  if(@poi_location,
                    do: "border-green-300 bg-green-50 text-green-700",
                    else: "border-gray-200 bg-gray-50 text-gray-500"
                  )
                ]}>
                  <.icon
                    name={if @poi_location, do: "hero-check-circle", else: "hero-map-pin"}
                    class="w-4 h-4 shrink-0"
                  />
                  <span class="truncate">
                    <%= if @poi_location do %>
                      {format_coords(@poi_location)}
                    <% else %>
                      No location selected
                    <% end %>
                  </span>
                </div>
                <button
                  type="button"
                  phx-click="pick_location_again"
                  class="px-3 py-2 rounded-xl border border-gray-200 bg-white text-sm text-gray-700 hover:bg-gray-50 active:scale-95 transition-all whitespace-nowrap"
                >
                  {if @poi_location, do: "Change", else: "Pick"}
                </button>
              </div>

              <%!-- Form errors --%>
              <%= if @poi_errors != [] do %>
                <div class="rounded-xl bg-red-50 border border-red-200 p-3 space-y-1">
                  <%= for {_field, msg} <- @poi_errors do %>
                    <p class="text-xs text-red-600">{msg}</p>
                  <% end %>
                </div>
              <% end %>

              <%!-- Name --%>
              <div>
                <label for="poi-name" class="block text-sm font-medium text-gray-700 mb-1">
                  Name <span class="text-red-500">*</span>
                </label>
                <input
                  id="poi-name"
                  type="text"
                  name="poi[name]"
                  value={@poi_name}
                  placeholder="e.g. Great viewpoint"
                  required
                  class="w-full px-3 py-2 rounded-xl border border-gray-300 bg-white text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500/30 focus:border-blue-500 transition text-sm"
                />
              </div>

              <%!-- Description --%>
              <div>
                <label
                  for="poi-description"
                  class="block text-sm font-medium text-gray-700 mb-1"
                >
                  Description
                </label>
                <textarea
                  id="poi-description"
                  name="poi[description]"
                  rows="2"
                  placeholder="Optional — describe this location…"
                  class="w-full px-3 py-2 rounded-xl border border-gray-300 bg-white text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500/30 focus:border-blue-500 transition text-sm resize-none"
                >{@poi_description}</textarea>
              </div>

              <%!-- Category --%>
              <div>
                <label for="poi-category" class="block text-sm font-medium text-gray-700 mb-2">
                  Category
                </label>
                <div class="grid grid-cols-3 gap-2">
                  <%= for cat <- @poi_categories do %>
                    <label class={[
                      "flex flex-col items-center gap-1 p-2 rounded-xl border cursor-pointer transition-all",
                      if(to_string(cat) == @poi_category,
                        do: "border-blue-500 bg-blue-50 text-blue-700",
                        else: "border-gray-200 bg-white text-gray-600 hover:border-gray-300"
                      )
                    ]}>
                      <input
                        type="radio"
                        name="poi[category]"
                        value={cat}
                        checked={to_string(cat) == @poi_category}
                        class="sr-only"
                      />
                      <.icon
                        name={category_icon(cat)}
                        class={[
                          "w-5 h-5",
                          if(to_string(cat) == @poi_category, do: "text-blue-600", else: "")
                        ]}
                      />
                      <span class="text-xs font-medium capitalize">
                        {cat |> to_string() |> String.replace("_", " ")}
                      </span>
                    </label>
                  <% end %>
                </div>
              </div>

              <%!-- Photos --%>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Photos <span class="text-gray-400 font-normal">(optional, up to 5)</span>
                </label>
                <div class="flex items-center gap-2">
                  <label
                    for={@uploads.photos.ref}
                    class="flex items-center gap-2 px-3 py-2 rounded-xl border border-dashed border-gray-300 bg-gray-50 text-sm text-gray-600 hover:bg-gray-100 cursor-pointer transition-colors"
                  >
                    <.icon name="hero-camera" class="w-4 h-4" /> Add photos
                    <.live_file_input upload={@uploads.photos} class="sr-only" />
                  </label>
                  <%= if length(@uploads.photos.entries) > 0 do %>
                    <span class="text-xs text-gray-500">
                      {length(@uploads.photos.entries)} selected
                    </span>
                  <% end %>
                </div>
                <%!-- Upload previews --%>
                <%= if length(@uploads.photos.entries) > 0 do %>
                  <div class="mt-2 flex gap-2 flex-wrap">
                    <%= for entry <- @uploads.photos.entries do %>
                      <div class="relative">
                        <.live_img_preview entry={entry} class="w-16 h-16 object-cover rounded-lg" />
                        <button
                          type="button"
                          phx-click="cancel_upload"
                          phx-value-ref={entry.ref}
                          class="absolute -top-1 -right-1 w-5 h-5 bg-red-500 rounded-full flex items-center justify-center"
                        >
                          <.icon name="hero-x-mark" class="w-3 h-3 text-white" />
                        </button>
                        <%= if entry.progress > 0 and entry.progress < 100 do %>
                          <div class="absolute inset-0 bg-black/40 rounded-lg flex items-center justify-center">
                            <span class="text-white text-xs font-bold">{entry.progress}%</span>
                          </div>
                        <% end %>
                        <%= for err <- upload_errors(@uploads.photos, entry) do %>
                          <p class="text-xs text-red-600 mt-1">{upload_error_to_string(err)}</p>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <%!-- Actions --%>
              <div class="flex gap-2 pt-1 pb-2">
                <button
                  type="submit"
                  name="publish"
                  value="false"
                  class="flex-1 py-2.5 rounded-xl border border-gray-300 bg-white text-sm font-semibold text-gray-700 hover:bg-gray-50 active:scale-95 transition-all"
                >
                  Save draft
                </button>
                <button
                  type="submit"
                  name="publish"
                  value="true"
                  class="flex-1 py-2.5 rounded-xl bg-blue-600 text-white text-sm font-semibold hover:bg-blue-700 active:scale-95 transition-all"
                >
                  Publish
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Activity feed drawer --%>
      <div
        id="activity-drawer"
        class={[
          "fixed bottom-0 left-0 right-0 z-20 transform transition-transform duration-300 ease-in-out",
          @poi_step != :idle && "opacity-0 pointer-events-none",
          if(not @drawer_open, do: "translate-y-[calc(100%-3.5rem)]")
        ]}
      >
        <div class="bg-white rounded-t-2xl border-t border-gray-200 shadow-2xl">
          <%!-- Drawer handle / toggle button --%>
          <button
            id="drawer-toggle"
            phx-click="toggle_drawer"
            class="w-full py-3 flex flex-col items-center gap-1 focus:outline-none"
          >
            <div class="w-10 h-1 bg-gray-200 rounded-full" />
            <div class="flex items-center gap-2">
              <.icon name="hero-bell" class="w-4 h-4 text-gray-400" />
              <span class="text-xs font-medium text-gray-500">Activity</span>
              <%= if @unread_count > 0 do %>
                <span class="inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-blue-600 rounded-full">
                  {if @unread_count > 9, do: "9+", else: @unread_count}
                </span>
              <% end %>
            </div>
          </button>

          <%!-- Feed entries --%>
          <div id="activity-entries" class="px-4 pb-6 max-h-72 overflow-y-auto space-y-2">
            <%= if Enum.empty?(@entries) do %>
              <p class="text-center text-sm text-gray-400 py-4">
                No activity yet. Start exploring!
              </p>
            <% end %>
            <%= for entry <- @entries do %>
              <div class="flex items-start gap-3 py-2 border-b border-gray-100 last:border-0">
                <div class="w-8 h-8 bg-blue-50 rounded-full flex items-center justify-center shrink-0 mt-0.5">
                  <.icon name={entry_icon(entry.action)} class="w-4 h-4 text-blue-600" />
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-sm text-gray-800 leading-snug">{entry.message}</p>
                  <p class="text-xs text-gray-400 mt-0.5">
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

  @spec format_coords(Geo.Point.t()) :: String.t()
  defp format_coords(%Geo.Point{coordinates: {lng, lat}}) do
    lat_str = :erlang.float_to_binary(lat, decimals: 5)
    lng_str = :erlang.float_to_binary(lng, decimals: 5)
    "#{lat_str}, #{lng_str}"
  end

  @spec upload_error_to_string(atom()) :: String.t()
  defp upload_error_to_string(:too_large), do: "File too large (max 10 MB)"
  defp upload_error_to_string(:not_accepted), do: "Unsupported file type"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_to_string(_), do: "Upload error"

  @spec entry_icon(atom()) :: String.t()
  defp entry_icon(:poi_published), do: "hero-map-pin"
  defp entry_icon(:geofence_published), do: "hero-map"
  defp entry_icon(:joined_event), do: "hero-user-plus"
  defp entry_icon(:comment_added), do: "hero-chat-bubble-left"
  defp entry_icon(:entered_geofence), do: "hero-arrow-right-circle"
  defp entry_icon(:exited_geofence), do: "hero-arrow-left-circle"
  defp entry_icon(_), do: "hero-bell"

  @spec category_icon(atom()) :: String.t()
  defp category_icon(:viewpoint), do: "hero-eye"
  defp category_icon(:camp), do: "hero-home"
  defp category_icon(:hazard), do: "hero-exclamation-triangle"
  defp category_icon(:meeting_point), do: "hero-user-group"
  defp category_icon(:food), do: "hero-shopping-bag"
  defp category_icon(:other), do: "hero-tag"
end
