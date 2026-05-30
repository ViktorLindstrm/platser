defmodule PlatserWeb.MapLive do
  use PlatserWeb, :live_view

  alias Platser.Activity
  alias Platser.Activity.Entry
  alias Platser.EventPresence
  alias Platser.Events.Event
  alias Platser.Location
  alias Platser.Map, as: PlatserMap
  alias Platser.Map.Geofence
  alias Platser.Map.Poi
  alias Platser.Media
  alias Platser.Media.Attachment
  alias PlatserWeb.MapInspection

  @pmtiles_url Application.compile_env(
                 :platser,
                 :pmtiles_url,
                 "pmtiles://https://r2-public.protomaps.com/protomaps-sample-datasets/nz.pmtiles"
               )

  @poi_categories [:viewpoint, :camp, :hazard, :meeting_point, :food, :other]
  @geofence_purposes [:boundary, :meeting_zone, :restricted, :camp_area, :other]
  @purpose_colors %{
    "boundary" => "#3B82F6",
    "meeting_zone" => "#10B981",
    "restricted" => "#EF4444",
    "camp_area" => "#F59E0B",
    "other" => "#6366F1"
  }

  @type map_object_msg ::
          {:poi_added, Poi.t()}
          | {:poi_updated, Poi.t()}
          | {:poi_removed, Ecto.UUID.t()}
          | {:geofence_added, Geofence.t()}
          | {:geofence_updated, Geofence.t()}
          | {:geofence_removed, Ecto.UUID.t()}

  @type activity_msg :: {:entry_added, Entry.t()}

  @type location_update_params :: %{
          String.t() => float() | nil
        }

  @type poi_step :: :idle | :picking | :editing
  @type geofence_step :: :idle | :drawing | :editing
  @type editing_published :: boolean()
  @type selected_map_object :: %{
          kind: MapInspection.kind(),
          item: Poi.t() | Geofence.t(),
          attachments: [Attachment.t()]
        }
  @type editing_id :: Ecto.UUID.t() | nil

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    session = if is_map(session), do: session, else: %{}

    event_id = Map.get(params, "event_id") || Map.get(session, "event_id")
    actor = socket.assigns[:current_user] || Map.get(session, "current_user")

    if is_nil(event_id) or is_nil(actor) do
      {:ok,
       socket
       |> put_flash(:error, "Event not found or you are not a member.")
       |> push_navigate(to: ~p"/")}
    else
      case load_event(event_id, actor) do
        {:ok, event} ->
          {pois, geofences, entries} = load_map_data(event_id, actor)
          is_admin = admin_member?(event_id, actor.id, actor)

          socket =
            socket
            |> assign(:event, event)
            |> assign(:is_admin, is_admin)
            |> assign(:pois, pois)
            |> assign(:geofences, geofences)
            |> stream(:entries, entries)
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
            |> assign(:geofence_step, :idle)
            |> assign(:geofence_vertices, [])
            |> assign(:geofence_geometry, nil)
            |> assign(:geofence_name, "")
            |> assign(:geofence_description, "")
            |> assign(:geofence_purpose, "boundary")
            |> assign(:geofence_color, Map.fetch!(@purpose_colors, "boundary"))
            |> assign(:geofence_errors, [])
            |> assign(:geofence_purposes, @geofence_purposes)
            |> assign(:purpose_colors, @purpose_colors)
            |> assign(:selected_map_object, nil)
            |> assign(:selected_map_object_can_manage, false)
            |> assign(:editing_poi_id, nil)
            |> assign(:editing_poi_published, false)
            |> assign(:editing_geofence_id, nil)
            |> assign(:editing_geofence_published, false)
            |> allow_upload(:photos,
              accept: ~w(.jpg .jpeg .png .webp),
              max_entries: 5,
              max_file_size: 10_000_000
            )

          socket =
            if connected?(socket) do
              Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event_id}:map_objects")
              Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event_id}:activity")
              Phoenix.PubSub.subscribe(Platser.PubSub, EventPresence.topic(event_id))
              send(self(), :push_map_init)
              socket
            else
              socket
            end

          {:ok,
           socket
           |> assign(:sharing?, false)
           |> assign(:location_tracked?, false)}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Event not found or you are not a member.")
           |> push_navigate(to: ~p"/")}
      end
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:push_map_init, socket) do
    event_id = socket.assigns.event.id

    map_payload = %{
      pois: to_geojson_feature_collection(socket.assigns.pois, &poi_to_feature/1),
      geofences: to_geojson_feature_collection(socket.assigns.geofences, &geofence_to_feature/1),
      bounds: bounds_to_map(socket.assigns.event.bounds)
    }

    member_locations =
      EventPresence.list_locations(event_id)
      |> Enum.map(fn {user_id, meta} ->
        %{
          user_id: user_id,
          lat: meta.lat,
          lng: meta.lng,
          display_name: Map.get(meta, :display_name, ""),
          is_simulated: Map.get(meta, :is_simulated, false)
        }
      end)

    socket =
      socket
      |> push_event("map_init", map_payload)
      |> push_event("member_locations_init", %{locations: member_locations})

    {:noreply, socket}
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
     |> stream_insert(:entries, entry, at: 0)
     |> update(:unread_count, fn count ->
       if socket.assigns.drawer_open, do: count, else: count + 1
     end)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff},
        socket
      ) do
    my_user_id = socket.assigns.current_user.id
    event_id = socket.assigns.event.id
    topic = EventPresence.topic(event_id)

    socket =
      Enum.reduce(diff.joins, socket, fn {user_id, %{metas: [meta | _]}}, acc ->
        if user_id != my_user_id do
          push_event(acc, "member_location_updated", %{
            user_id: user_id,
            lat: meta.lat,
            lng: meta.lng,
            display_name: Map.get(meta, :display_name, ""),
            is_simulated: Map.get(meta, :is_simulated, false)
          })
        else
          acc
        end
      end)

    socket =
      Enum.reduce(diff.leaves, socket, fn {user_id, _}, acc ->
        if user_id != my_user_id do
          current = EventPresence.list(topic)

          case Map.get(current, user_id) do
            %{metas: [latest | _]} ->
              push_event(acc, "member_location_updated", %{
                user_id: user_id,
                lat: latest.lat,
                lng: latest.lng,
                display_name: Map.get(latest, :display_name, ""),
                is_simulated: Map.get(latest, :is_simulated, false)
              })

            _ ->
              push_event(acc, "member_location_removed", %{user_id: user_id})
          end
        else
          acc
        end
      end)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_drawer", _params, socket) do
    drawer_open = !socket.assigns.drawer_open

    {:noreply,
     socket
     |> assign(:drawer_open, drawer_open)
     |> assign(:unread_count, if(drawer_open, do: 0, else: socket.assigns.unread_count))}
  end

  def handle_event(
        "save_map_bounds",
        %{"west" => west, "south" => south, "east" => east, "north" => north},
        socket
      ) do
    actor = socket.assigns.current_user

    with :ok <- validate_bounds(west, south, east, north),
         bounds_polygon = build_bounds_polygon(west, south, east, north),
         {:ok, updated_event} <-
           Platser.Events.set_event_bounds(socket.assigns.event, bounds_polygon, actor: actor) do
      {:noreply,
       socket
       |> assign(:event, updated_event)
       |> push_event("fit_bounds", bounds_to_map(updated_event.bounds))
       |> put_flash(:info, "Map area saved.")}
    else
      {:error, :invalid_bounds} ->
        {:noreply, put_flash(socket, :error, "Invalid bounds — could not save map area.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save map area.")}
    end
  end

  def handle_event("toggle_sharing", _params, socket) do
    if socket.assigns.sharing? do
      event_id = socket.assigns.event.id
      topic = EventPresence.topic(event_id)
      EventPresence.untrack(self(), topic, socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(:sharing?, false)
       |> assign(:location_tracked?, false)
       |> push_event("stop_sharing", %{})}
    else
      {:noreply,
       socket
       |> assign(:sharing?, true)
       |> push_event("start_sharing", %{})}
    end
  end

  def handle_event(
        "location_update",
        %{"lat" => lat, "lng" => lng} = params,
        socket
      ) do
    if socket.assigns.sharing? do
      event_id = socket.assigns.event.id
      user = socket.assigns.current_user
      already_tracked? = socket.assigns.location_tracked?

      location_params = %{
        lat: ensure_float(lat),
        lng: ensure_float(lng),
        accuracy: maybe_float(params["accuracy"]),
        heading: maybe_float(params["heading"])
      }

      case Location.update_presence(self(), event_id, user, location_params, already_tracked?) do
        {:ok, _meta} ->
          {:noreply, assign(socket, :location_tracked?, true)}

        {:error, :invalid_coords} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_poi_form", _params, socket) do
    socket =
      socket
      |> assign(:selected_map_object, nil)
      |> assign(:selected_map_object_can_manage, false)
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

  def handle_event("inspect_map_object", %{"kind" => kind, "id" => id}, socket) do
    actor = socket.assigns.current_user

    case load_selected_map_object(kind, id, actor) do
      {:ok, selected_map_object} ->
        {:noreply,
         socket
         |> assign(:selected_map_object, selected_map_object)
         |> assign(
           :selected_map_object_can_manage,
           can_manage_selected_map_object?(selected_map_object.item, actor)
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:selected_map_object, nil)
         |> assign(:selected_map_object_can_manage, false)
         |> put_flash(:error, "Could not load that map item")}
    end
  end

  def handle_event("clear_map_object_inspection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_map_object, nil)
     |> assign(:selected_map_object_can_manage, false)}
  end

  def handle_event("focus_selected_map_object", _params, socket) do
    case socket.assigns.selected_map_object do
      nil ->
        {:noreply, socket}

      selected_map_object ->
        {:noreply,
         push_event(socket, "focus_map_object", focus_map_object_payload(selected_map_object))}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photos, ref)}
  end

  def handle_event("edit_selected_map_object", _params, socket) do
    case socket.assigns.selected_map_object do
      %{kind: :poi, item: %Poi{} = poi} ->
        {:noreply,
         socket
         |> assign(:selected_map_object, nil)
         |> assign(:selected_map_object_can_manage, false)
         |> assign(:editing_poi_id, poi.id)
         |> assign(:editing_poi_published, poi.visibility == :public)
         |> assign(:editing_geofence_id, nil)
         |> assign(:editing_geofence_published, false)
         |> assign(:geofence_step, :idle)
         |> assign(:poi_step, :editing)
         |> assign(:poi_location, poi.location)
         |> assign(:poi_name, poi.name)
         |> assign(:poi_description, poi.description || "")
         |> assign(:poi_category, to_string(poi.category))
         |> assign(:poi_errors, [])}

      %{kind: :geofence, item: %Geofence{} = geofence} ->
        {:noreply,
         socket
         |> assign(:selected_map_object, nil)
         |> assign(:selected_map_object_can_manage, false)
         |> assign(:editing_geofence_id, geofence.id)
         |> assign(:editing_geofence_published, geofence.visibility == :public)
         |> assign(:editing_poi_id, nil)
         |> assign(:editing_poi_published, false)
         |> assign(:poi_step, :idle)
         |> assign(:geofence_step, :editing)
         |> assign(:geofence_vertices, [])
         |> assign(:geofence_geometry, geofence.geometry)
         |> assign(:geofence_name, geofence.name)
         |> assign(:geofence_description, geofence.description || "")
         |> assign(:geofence_purpose, to_string(geofence.purpose))
         |> assign(:geofence_color, geofence.color)
         |> assign(:geofence_errors, [])}

      nil ->
        {:noreply, socket}
    end
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
    socket =
      socket
      |> assign(:poi_name, params["name"] || "")
      |> assign(:poi_description, params["description"] || "")

    socket =
      if Map.has_key?(params, "category") do
        assign(socket, :poi_category, params["category"])
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save_poi", %{"poi" => params} = event_params, socket) do
    publish? = Map.get(event_params, "publish") == "true"
    submit_poi(params, publish?, socket)
  end

  def handle_event("open_geofence_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_map_object, nil)
     |> assign(:selected_map_object_can_manage, false)
     |> assign(:geofence_step, :drawing)
     |> assign(:geofence_vertices, [])
     |> assign(:geofence_geometry, nil)
     |> assign(:geofence_name, "")
     |> assign(:geofence_description, "")
     |> assign(:geofence_purpose, "boundary")
     |> assign(:geofence_color, Map.fetch!(@purpose_colors, "boundary"))
     |> assign(:geofence_errors, [])
     |> push_event("enable_draw_mode", %{})}
  end

  def handle_event("cancel_geofence_form", _params, socket) do
    {:noreply, reset_geofence_form(socket)}
  end

  def handle_event("save_map_object_comment", %{"comment" => comment}, socket) do
    actor = socket.assigns.current_user

    case socket.assigns.selected_map_object do
      %{kind: :poi, item: %Poi{} = poi} ->
        case PlatserMap.update_poi_metadata(poi, %{comment: comment}, actor: actor) do
          {:ok, updated} ->
            {:noreply, select_map_object(socket, :poi, updated)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save comment.")}
        end

      %{kind: :geofence, item: %Geofence{} = geofence} ->
        case PlatserMap.update_geofence_metadata(geofence, %{comment: comment}, actor: actor) do
          {:ok, updated} ->
            {:noreply, select_map_object(socket, :geofence, updated)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save comment.")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("publish_selected_map_object", _params, socket) do
    case socket.assigns.selected_map_object do
      %{kind: :poi, item: %Poi{} = poi} ->
        case PlatserMap.publish_poi(poi, actor: socket.assigns.current_user) do
          {:ok, published} ->
            {:noreply,
             socket
             |> select_map_object(:poi, published)
             |> push_event("poi_updated", poi_to_feature(published))
             |> put_flash(:info, "POI published!")}

          {:error, %Ash.Error.Invalid{} = err} ->
            msg = Ash.Error.to_error_class(err).message || "Could not publish POI"
            {:noreply, put_flash(socket, :error, msg)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not publish POI")}
        end

      %{kind: :geofence, item: %Geofence{} = geofence} ->
        case PlatserMap.publish_geofence(geofence, actor: socket.assigns.current_user) do
          {:ok, published} ->
            {:noreply,
             socket
             |> select_map_object(:geofence, published)
             |> push_event("geofence_updated", geofence_to_feature(published))
             |> put_flash(:info, "Geofence published!")}

          {:error, %Ash.Error.Invalid{} = err} ->
            msg = Ash.Error.to_error_class(err).message || "Could not publish geofence"
            {:noreply, put_flash(socket, :error, msg)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not publish geofence")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_selected_map_object", _params, socket) do
    case socket.assigns.selected_map_object do
      %{kind: :poi, item: %Poi{} = poi} ->
        case PlatserMap.delete_poi(poi, actor: socket.assigns.current_user) do
          :ok ->
            {:noreply,
             socket
             |> assign(:selected_map_object, nil)
             |> assign(:selected_map_object_can_manage, false)
             |> push_event("poi_removed", %{"id" => poi.id})
             |> put_flash(:info, "POI deleted")}

          {:ok, _deleted} ->
            {:noreply,
             socket
             |> assign(:selected_map_object, nil)
             |> assign(:selected_map_object_can_manage, false)
             |> push_event("poi_removed", %{"id" => poi.id})
             |> put_flash(:info, "POI deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete POI")}
        end

      %{kind: :geofence, item: %Geofence{} = geofence} ->
        case PlatserMap.delete_geofence(geofence, actor: socket.assigns.current_user) do
          :ok ->
            {:noreply,
             socket
             |> assign(:selected_map_object, nil)
             |> assign(:selected_map_object_can_manage, false)
             |> push_event("geofence_removed", %{"id" => geofence.id})
             |> put_flash(:info, "Geofence deleted")}

          {:ok, _deleted} ->
            {:noreply,
             socket
             |> assign(:selected_map_object, nil)
             |> assign(:selected_map_object_can_manage, false)
             |> push_event("geofence_removed", %{"id" => geofence.id})
             |> put_flash(:info, "Geofence deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete geofence")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("vertex_added", %{"vertices" => vertices}, socket) do
    {:noreply, assign(socket, :geofence_vertices, vertices)}
  end

  def handle_event("undo_last_vertex", _params, socket) do
    {:noreply, push_event(socket, "undo_last_vertex", %{})}
  end

  def handle_event("finish_drawing", _params, socket) do
    vertices = socket.assigns.geofence_vertices

    if length(vertices) < 3 do
      {:noreply, socket}
    else
      ring = Enum.map(vertices, fn [lng, lat] -> {lng, lat} end)
      ring_closed = ring ++ [List.first(ring)]
      geometry = %Geo.Polygon{coordinates: [ring_closed], srid: 4326}

      {:noreply,
       socket
       |> assign(:geofence_step, :editing)
       |> assign(:geofence_geometry, geometry)
       |> push_event("disable_draw_mode", %{})}
    end
  end

  def handle_event("validate_geofence", %{"geofence" => params}, socket) do
    purpose = params["purpose"] || socket.assigns.geofence_purpose
    prev_purpose = socket.assigns.geofence_purpose

    color =
      cond do
        purpose != prev_purpose ->
          Map.get(@purpose_colors, purpose, socket.assigns.geofence_color)

        Map.has_key?(params, "color") ->
          params["color"]

        true ->
          socket.assigns.geofence_color
      end

    {:noreply,
     socket
     |> assign(:geofence_name, params["name"] || "")
     |> assign(:geofence_description, params["description"] || "")
     |> assign(:geofence_purpose, purpose)
     |> assign(:geofence_color, color)}
  end

  def handle_event("save_geofence", %{"geofence" => params} = event_params, socket) do
    publish? = Map.get(event_params, "publish") == "true"
    submit_geofence(params, publish?, socket)
  end

  @spec submit_poi(map(), boolean(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp submit_poi(params, publish?, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    if socket.assigns.editing_poi_published do
      name = String.trim(params["name"] || "")

      if name == "" do
        {:noreply, assign(socket, :poi_errors, [{"name", "can't be blank"}])}
      else
        poi_attrs = %{name: name, description: params["description"]}

        case socket.assigns.editing_poi_id do
          nil -> {:noreply, socket}
          poi_id -> do_update_poi(poi_id, poi_attrs, false, socket, actor)
        end
      end
    else
      location = socket.assigns.poi_location
      errors = validate_poi_params(params, location)

      if errors != [] do
        {:noreply, assign(socket, :poi_errors, errors)}
      else
        poi_attrs = %{
          name: String.trim(params["name"]),
          description: params["description"],
          category: String.to_existing_atom(params["category"]),
          location: location
        }

        case socket.assigns.editing_poi_id do
          nil ->
            do_create_poi(Map.put(poi_attrs, :event_id, event.id), publish?, socket, actor)

          poi_id ->
            do_update_poi(poi_id, poi_attrs, publish?, socket, actor)
        end
      end
    end
  end

  @spec do_create_poi(map(), boolean(), Phoenix.LiveView.Socket.t(), Platser.Accounts.User.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_create_poi(params, publish?, socket, actor) do
    case PlatserMap.create_poi(params, actor: actor) do
      {:ok, poi} ->
        _uploaded_paths = handle_photo_uploads(socket, poi, actor)

        socket =
          if publish? do
            case PlatserMap.publish_poi(poi, actor: actor) do
              {:ok, published} ->
                socket
                |> reset_poi_form()
                |> select_map_object(:poi, published)
                |> push_event("poi_added", poi_to_feature(published))
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
            |> select_map_object(:poi, poi)
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

  @spec do_update_poi(
          Ecto.UUID.t(),
          map(),
          boolean(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_poi(poi_id, attrs, publish?, socket, actor) do
    case PlatserMap.get_poi(poi_id, actor: actor) do
      {:ok, poi} ->
        if poi.visibility == :public do
          do_update_poi_metadata(poi, attrs, socket, actor)
        else
          do_update_poi_draft(poi, attrs, publish?, socket, actor)
        end

      {:error, _} ->
        {:noreply, assign(socket, :poi_errors, [{"base", "POI not found or was deleted"}])}
    end
  end

  @spec do_update_poi_metadata(
          Platser.Map.Poi.t(),
          map(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_poi_metadata(poi, attrs, socket, actor) do
    case PlatserMap.update_poi_metadata(poi, attrs, actor: actor) do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{updated.event_id}:map_objects",
          {:poi_updated, updated}
        )

        {:noreply,
         socket
         |> reset_poi_form()
         |> select_map_object(:poi, updated)
         |> push_event("poi_updated", poi_to_feature(updated))
         |> put_flash(:info, "POI updated.")}

      {:error, %Ash.Error.Invalid{} = err} ->
        errors = format_ash_errors(err)
        {:noreply, assign(socket, :poi_errors, errors)}

      {:error, _} ->
        {:noreply, assign(socket, :poi_errors, [{"base", "Could not update POI"}])}
    end
  end

  @spec do_update_poi_draft(
          Platser.Map.Poi.t(),
          map(),
          boolean(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_poi_draft(poi, attrs, publish?, socket, actor) do
    case PlatserMap.update_poi(poi, attrs, actor: actor) do
      {:ok, updated} ->
        socket =
          if publish? do
            case PlatserMap.publish_poi(updated, actor: actor) do
              {:ok, published} ->
                socket
                |> reset_poi_form()
                |> select_map_object(:poi, published)
                |> push_event("poi_updated", poi_to_feature(published))
                |> put_flash(:info, "POI updated and published!")

              {:error, _} ->
                socket
                |> reset_poi_form()
                |> select_map_object(:poi, updated)
                |> push_event("poi_updated", poi_to_feature(updated))
                |> put_flash(:info, "POI saved.")
            end
          else
            socket
            |> reset_poi_form()
            |> select_map_object(:poi, updated)
            |> push_event("poi_updated", poi_to_feature(updated))
            |> put_flash(:info, "POI saved.")
          end

        {:noreply, socket}

      {:error, %Ash.Error.Invalid{} = err} ->
        errors = format_ash_errors(err)
        {:noreply, assign(socket, :poi_errors, errors)}

      {:error, _} ->
        {:noreply, assign(socket, :poi_errors, [{"base", "Could not update POI"}])}
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
  defp uploads_dir_for(owner_id) do
    Application.app_dir(:platser, "priv/static/uploads/#{owner_id}")
  end

  @spec handle_photo_uploads_for_geofence(
          Phoenix.LiveView.Socket.t(),
          Geofence.t(),
          Platser.Accounts.User.t()
        ) :: [String.t()]
  defp handle_photo_uploads_for_geofence(socket, geofence, actor) do
    dir = uploads_dir_for(geofence.id)
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :photos, fn %{path: tmp_path}, entry ->
      stored_filename = "#{Ecto.UUID.generate()}_#{Path.basename(entry.client_name)}"
      dest = Path.join(dir, stored_filename)

      case File.cp(tmp_path, dest) do
        :ok ->
          url_path = "/uploads/#{geofence.id}/#{stored_filename}"

          Platser.Media.create_geofence_attachment(
            %{
              filename: entry.client_name,
              stored_filename: stored_filename,
              content_type: entry.client_type,
              path: url_path,
              geofence_id: geofence.id
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
    |> cancel_all_photo_uploads()
    |> assign(:poi_step, :idle)
    |> assign(:poi_location, nil)
    |> assign(:poi_name, "")
    |> assign(:poi_description, "")
    |> assign(:poi_category, "viewpoint")
    |> assign(:poi_errors, [])
    |> assign(:editing_poi_id, nil)
    |> assign(:editing_poi_published, false)
    |> push_event("disable_location_pick", %{})
  end

  @spec reset_geofence_form(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_geofence_form(socket) do
    socket
    |> cancel_all_photo_uploads()
    |> assign(:geofence_step, :idle)
    |> assign(:geofence_vertices, [])
    |> assign(:geofence_geometry, nil)
    |> assign(:geofence_name, "")
    |> assign(:geofence_description, "")
    |> assign(:geofence_purpose, "boundary")
    |> assign(:geofence_color, Map.fetch!(@purpose_colors, "boundary"))
    |> assign(:geofence_errors, [])
    |> assign(:editing_geofence_id, nil)
    |> assign(:editing_geofence_published, false)
    |> push_event("disable_draw_mode", %{})
  end

  @spec cancel_all_photo_uploads(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp cancel_all_photo_uploads(socket) do
    socket.assigns.uploads.photos.entries
    |> Enum.reduce(socket, fn entry, acc ->
      cancel_upload(acc, :photos, entry.ref)
    end)
  end

  @spec load_selected_map_object(String.t(), String.t(), Platser.Accounts.User.t()) ::
          {:ok, selected_map_object()} | {:error, :not_found}
  defp load_selected_map_object("poi", id, actor) do
    case PlatserMap.get_poi(id, actor: actor) do
      {:ok, %Poi{} = poi} ->
        poi = load_item_creator(poi, actor)
        {:ok, %{kind: :poi, item: poi, attachments: load_poi_attachments(poi.id, actor)}}

      _ ->
        {:error, :not_found}
    end
  end

  defp load_selected_map_object("geofence", id, actor) do
    case PlatserMap.get_geofence(id, actor: actor) do
      {:ok, %Geofence{} = geofence} ->
        geofence = load_item_creator(geofence, actor)

        {:ok,
         %{
           kind: :geofence,
           item: geofence,
           attachments: load_geofence_attachments(geofence.id, actor)
         }}

      _ ->
        {:error, :not_found}
    end
  end

  defp load_selected_map_object(_, _, _), do: {:error, :not_found}

  @spec load_poi_attachments(Ecto.UUID.t(), Platser.Accounts.User.t()) :: [Attachment.t()]
  defp load_poi_attachments(poi_id, actor) do
    case Media.list_attachments_for_poi(poi_id, actor: actor) do
      {:ok, attachments} ->
        attachments

      {:error, %Ash.Error.Forbidden{}} ->
        []

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to load attachments for POI #{poi_id}: #{inspect(reason)}")
        []
    end
  end

  @spec load_geofence_attachments(Ecto.UUID.t(), Platser.Accounts.User.t()) :: [Attachment.t()]
  defp load_geofence_attachments(geofence_id, actor) do
    case Media.list_attachments_for_geofence(geofence_id, actor: actor) do
      {:ok, attachments} ->
        attachments

      {:error, %Ash.Error.Forbidden{}} ->
        []

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to load attachments for Geofence #{geofence_id}: #{inspect(reason)}"
        )

        []
    end
  end

  @spec load_item_creator(Poi.t() | Geofence.t(), Platser.Accounts.User.t()) ::
          Poi.t() | Geofence.t()
  defp load_item_creator(item, actor) do
    case Ash.load(item, [:creator], actor: actor) do
      {:ok, loaded} ->
        loaded

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to load creator for #{item.id}: #{inspect(reason)}")
        item
    end
  end

  defp focus_map_object_payload(%{kind: :poi, item: %Poi{} = poi}) do
    %{
      kind: "poi",
      geometry: Geo.JSON.encode!(poi.location)
    }
  end

  defp focus_map_object_payload(%{kind: :geofence, item: %Geofence{} = geofence}) do
    %{
      kind: "geofence",
      geometry: Geo.JSON.encode!(geofence.geometry)
    }
  end

  @spec select_map_object(
          Phoenix.LiveView.Socket.t(),
          :poi,
          Poi.t()
        ) :: Phoenix.LiveView.Socket.t()
  defp select_map_object(socket, :poi, %Poi{} = poi) do
    actor = socket.assigns.current_user
    poi = load_item_creator(poi, actor)
    attachments = load_poi_attachments(poi.id, actor)

    socket
    |> assign(:selected_map_object, %{kind: :poi, item: poi, attachments: attachments})
    |> assign(:selected_map_object_can_manage, can_manage_selected_map_object?(poi, actor))
  end

  @spec select_map_object(
          Phoenix.LiveView.Socket.t(),
          :geofence,
          Geofence.t()
        ) :: Phoenix.LiveView.Socket.t()
  defp select_map_object(socket, :geofence, %Geofence{} = geofence) do
    actor = socket.assigns.current_user
    geofence = load_item_creator(geofence, actor)
    attachments = load_geofence_attachments(geofence.id, actor)

    socket
    |> assign(:selected_map_object, %{kind: :geofence, item: geofence, attachments: attachments})
    |> assign(:selected_map_object_can_manage, can_manage_selected_map_object?(geofence, actor))
  end

  @spec can_manage_selected_map_object?(Poi.t() | Geofence.t(), Platser.Accounts.User.t() | nil) ::
          boolean()
  defp can_manage_selected_map_object?(_item, nil), do: false

  defp can_manage_selected_map_object?(%{creator_id: creator_id, event_id: event_id}, actor) do
    creator_id == actor.id or admin_member?(event_id, actor.id, actor)
  end

  @spec admin_member?(Ecto.UUID.t(), Ecto.UUID.t(), Platser.Accounts.User.t()) :: boolean()
  defp admin_member?(event_id, user_id, actor) do
    case Platser.Events.list_memberships_for_event(event_id, actor: actor) do
      {:ok, memberships} ->
        Enum.any?(memberships, fn membership ->
          membership.user_id == user_id and membership.role == :admin
        end)

      {:error, _} ->
        false
    end
  end

  @spec map_item_icon(MapInspection.kind()) :: String.t()
  defp map_item_icon(:poi), do: "hero-map-pin"
  defp map_item_icon(:geofence), do: "hero-map"

  @spec geofence_vertex_count(Geo.Polygon.t()) :: non_neg_integer()
  defp geofence_vertex_count(%Geo.Polygon{coordinates: [ring | _]}) do
    max(length(ring) - 1, 0)
  end

  defp geofence_vertex_count(_), do: 0

  @spec submit_geofence(map(), boolean(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp submit_geofence(params, publish?, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    if socket.assigns.editing_geofence_published do
      name = String.trim(params["name"] || "")

      if name == "" do
        {:noreply, assign(socket, :geofence_errors, [{"name", "can't be blank"}])}
      else
        geofence_attrs = %{
          name: name,
          description: params["description"],
          color: params["color"] || socket.assigns.geofence_color
        }

        case socket.assigns.editing_geofence_id do
          nil -> {:noreply, socket}
          geofence_id -> do_update_geofence(geofence_id, geofence_attrs, false, socket, actor)
        end
      end
    else
      geometry = socket.assigns.geofence_geometry
      errors = validate_geofence_params(params, geometry)

      if errors != [] do
        {:noreply, assign(socket, :geofence_errors, errors)}
      else
        case socket.assigns.editing_geofence_id do
          nil ->
            geofence_params = %{
              name: String.trim(params["name"]),
              description: params["description"],
              purpose: String.to_existing_atom(params["purpose"]),
              color: params["color"],
              geometry: geometry,
              event_id: event.id
            }

            do_create_geofence(geofence_params, publish?, socket, actor)

          geofence_id ->
            geofence_attrs = %{
              name: String.trim(params["name"]),
              description: params["description"],
              purpose: String.to_existing_atom(params["purpose"]),
              color: params["color"]
            }

            do_update_geofence(geofence_id, geofence_attrs, publish?, socket, actor)
        end
      end
    end
  end

  @spec do_create_geofence(
          map(),
          boolean(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_create_geofence(params, publish?, socket, actor) do
    case PlatserMap.create_geofence(params, actor: actor) do
      {:ok, geofence} ->
        _uploaded_paths = handle_photo_uploads_for_geofence(socket, geofence, actor)

        socket =
          if publish? do
            case PlatserMap.publish_geofence(geofence, actor: actor) do
              {:ok, published} ->
                socket
                |> reset_geofence_form()
                |> select_map_object(:geofence, published)
                |> push_event("geofence_added", geofence_to_feature(published))
                |> put_flash(:info, "Geofence published! Everyone can see it.")

              {:error, %Ash.Error.Invalid{} = err} ->
                msg = Ash.Error.to_error_class(err).message || "Could not publish geofence"
                socket |> reset_geofence_form() |> put_flash(:error, msg)

              {:error, _} ->
                socket
                |> reset_geofence_form()
                |> put_flash(:error, "Could not publish geofence")
            end
          else
            socket
            |> reset_geofence_form()
            |> select_map_object(:geofence, geofence)
            |> push_event("geofence_added", geofence_to_feature(geofence))
            |> put_flash(:info, "Geofence saved as draft. Only you can see it.")
          end

        {:noreply, socket}

      {:error, %Ash.Error.Invalid{} = err} ->
        errors = format_ash_errors(err)
        {:noreply, assign(socket, :geofence_errors, errors)}

      {:error, _} ->
        {:noreply, assign(socket, :geofence_errors, [{"base", "Could not save geofence"}])}
    end
  end

  @spec do_update_geofence(
          Ecto.UUID.t(),
          map(),
          boolean(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_geofence(geofence_id, attrs, publish?, socket, actor) do
    case PlatserMap.get_geofence(geofence_id, actor: actor) do
      {:ok, geofence} ->
        if geofence.visibility == :public do
          do_update_geofence_metadata(geofence, attrs, socket, actor)
        else
          do_update_geofence_draft(geofence, attrs, publish?, socket, actor)
        end

      {:error, _} ->
        {:noreply,
         assign(socket, :geofence_errors, [{"base", "Geofence not found or was deleted"}])}
    end
  end

  @spec do_update_geofence_metadata(
          Platser.Map.Geofence.t(),
          map(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_geofence_metadata(geofence, attrs, socket, actor) do
    case PlatserMap.update_geofence_metadata(geofence, attrs, actor: actor) do
      {:ok, updated} ->
        _uploaded_paths = handle_photo_uploads_for_geofence(socket, updated, actor)

        Phoenix.PubSub.broadcast(
          Platser.PubSub,
          "event:#{updated.event_id}:map_objects",
          {:geofence_updated, updated}
        )

        {:noreply,
         socket
         |> reset_geofence_form()
         |> select_map_object(:geofence, updated)
         |> push_event("geofence_updated", geofence_to_feature(updated))
         |> put_flash(:info, "Geofence updated.")}

      {:error, %Ash.Error.Invalid{} = err} ->
        errors = format_ash_errors(err)
        {:noreply, assign(socket, :geofence_errors, errors)}

      {:error, _} ->
        {:noreply, assign(socket, :geofence_errors, [{"base", "Could not update geofence"}])}
    end
  end

  @spec do_update_geofence_draft(
          Platser.Map.Geofence.t(),
          map(),
          boolean(),
          Phoenix.LiveView.Socket.t(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp do_update_geofence_draft(geofence, attrs, publish?, socket, actor) do
    case PlatserMap.update_geofence(geofence, attrs, actor: actor) do
      {:ok, updated} ->
        _uploaded_paths = handle_photo_uploads_for_geofence(socket, updated, actor)

        socket =
          if publish? do
            case PlatserMap.publish_geofence(updated, actor: actor) do
              {:ok, published} ->
                socket
                |> reset_geofence_form()
                |> select_map_object(:geofence, published)
                |> push_event("geofence_updated", geofence_to_feature(published))
                |> put_flash(:info, "Geofence updated and published!")

              {:error, _} ->
                socket
                |> reset_geofence_form()
                |> select_map_object(:geofence, updated)
                |> push_event("geofence_updated", geofence_to_feature(updated))
                |> put_flash(:info, "Geofence saved.")
            end
          else
            socket
            |> reset_geofence_form()
            |> select_map_object(:geofence, updated)
            |> push_event("geofence_updated", geofence_to_feature(updated))
            |> put_flash(:info, "Geofence saved.")
          end

        {:noreply, socket}

      {:error, %Ash.Error.Invalid{} = err} ->
        errors = format_ash_errors(err)
        {:noreply, assign(socket, :geofence_errors, errors)}

      {:error, _} ->
        {:noreply, assign(socket, :geofence_errors, [{"base", "Could not update geofence"}])}
    end
  end

  @spec validate_geofence_params(map(), Geo.Polygon.t() | nil) :: [{String.t(), String.t()}]
  defp validate_geofence_params(params, geometry) do
    []
    |> then(fn errs ->
      name = String.trim(params["name"] || "")
      if name == "", do: [{"name", "can't be blank"} | errs], else: errs
    end)
    |> then(fn errs ->
      if is_nil(geometry), do: [{"geometry", "draw a polygon on the map"} | errs], else: errs
    end)
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
          <div class="flex items-center gap-2 pointer-events-auto">
            <%!-- Activity feed toggle (desktop only) --%>
            <button
              id="feed-toggle-desktop"
              phx-click="toggle_drawer"
              class="hidden md:flex items-center gap-1.5 relative bg-white/90 backdrop-blur-sm rounded-xl px-3 py-2 shadow-lg border border-gray-200 hover:bg-white transition-colors"
            >
              <.icon name="hero-bell" class="w-4 h-4 text-gray-500" />
              <%= if @unread_count > 0 do %>
                <span class="absolute -top-1.5 -right-1.5 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-blue-600 rounded-full ring-2 ring-white">
                  {if @unread_count > 9, do: "9+", else: @unread_count}
                </span>
              <% end %>
            </button>
            <.link
              navigate={~p"/join/#{@event.join_code}"}
              class="bg-white/90 backdrop-blur-sm rounded-xl px-3 py-2 shadow-lg border border-gray-200"
            >
              <.icon name="hero-users" class="w-4 h-4 text-gray-500" />
            </.link>
          </div>
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

      <%!-- Geofence draw mode overlay --%>
      <%= if @geofence_step == :drawing do %>
        <div class="fixed top-16 left-0 right-0 z-30 flex justify-center pointer-events-none">
          <div class="bg-gray-900/90 backdrop-blur-sm text-white text-sm px-4 py-2.5 rounded-full shadow-xl flex items-center gap-3 pointer-events-auto">
            <.icon name="hero-pencil-square" class="w-4 h-4 text-indigo-400 animate-pulse" />
            <span class="font-medium">
              <%= cond do %>
                <% length(@geofence_vertices) == 0 -> %>
                  Tap map to start drawing
                <% length(@geofence_vertices) < 3 -> %>
                  {length(@geofence_vertices)} vertices — need {3 - length(@geofence_vertices)} more
                <% true -> %>
                  {length(@geofence_vertices)} vertices
              <% end %>
            </span>
            <%= if length(@geofence_vertices) > 0 do %>
              <button
                phx-click="undo_last_vertex"
                class="text-gray-400 hover:text-white transition-colors"
                title="Undo last vertex"
              >
                <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
              </button>
            <% end %>
            <button
              phx-click="finish_drawing"
              disabled={length(@geofence_vertices) < 3}
              class={[
                "px-3 py-1 rounded-full text-xs font-semibold transition-all",
                if(length(@geofence_vertices) >= 3,
                  do: "bg-indigo-500 hover:bg-indigo-400 text-white",
                  else: "bg-gray-700 text-gray-500 cursor-not-allowed"
                )
              ]}
            >
              Finish
            </button>
            <button
              phx-click="cancel_geofence_form"
              class="text-gray-400 hover:text-white transition-colors"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>
      <% end %>

      <%!-- Floating action buttons (bottom-right) --%>
      <div class={[
        "fixed bottom-24 right-4 z-20 flex flex-col gap-3 transition-all duration-300",
        (@poi_step != :idle or @geofence_step != :idle or @selected_map_object) &&
          "opacity-0 pointer-events-none"
      ]}>
        <%!-- Set map area (admin only) --%>
        <%= if @is_admin do %>
          <button
            id="set-map-area-btn"
            data-set-map-area="true"
            class="w-12 h-12 bg-white/90 backdrop-blur-sm rounded-full shadow-lg border border-gray-200 flex items-center justify-center hover:bg-amber-50 hover:border-amber-300 active:scale-95 transition-all"
            title="Set map area to current viewport"
          >
            <.icon name="hero-viewfinder-circle" class="w-5 h-5 text-amber-600" />
          </button>
        <% end %>
        <%!-- Share location toggle --%>
        <button
          id="share-location-btn"
          phx-click="toggle_sharing"
          class={[
            "w-12 h-12 rounded-full shadow-lg border flex items-center justify-center active:scale-95 transition-all",
            if(@sharing?,
              do:
                "bg-emerald-500 border-emerald-400 hover:bg-emerald-600 ring-4 ring-emerald-200 animate-pulse",
              else:
                "bg-white/90 backdrop-blur-sm border-gray-200 hover:bg-emerald-50 hover:border-emerald-300"
            )
          ]}
          title={if @sharing?, do: "Stop sharing location", else: "Share my location"}
        >
          <.icon
            name="hero-map-pin"
            class={["w-5 h-5", if(@sharing?, do: "text-white", else: "text-emerald-500")]}
          />
        </button>
        <button
          id="add-geofence-btn"
          phx-click="open_geofence_form"
          class="w-12 h-12 bg-white/90 backdrop-blur-sm rounded-full shadow-lg border border-gray-200 flex items-center justify-center hover:bg-indigo-50 hover:border-indigo-300 active:scale-95 transition-all"
          title="Draw geofence"
        >
          <.icon name="hero-map" class="w-5 h-5 text-indigo-500" />
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
            <h2 class="text-base font-semibold text-gray-900">
              {if @editing_poi_id, do: "Edit Point of Interest", else: "New Point of Interest"}
            </h2>
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
              <%!-- Location indicator (hidden when editing a published POI) --%>
              <%= if not @editing_poi_published do %>
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
              <% end %>

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

              <%!-- Category (hidden when editing a published POI) --%>
              <%= if not @editing_poi_published do %>
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
              <% end %>

              <%= if is_nil(@editing_poi_id) and @poi_step == :editing do %>
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
              <% end %>

              <%!-- Actions --%>
              <div class="flex gap-2 pt-1 pb-2">
                <button
                  type="submit"
                  name="publish"
                  value="false"
                  class="flex-1 py-2.5 rounded-xl border border-gray-300 bg-white text-sm font-semibold text-gray-700 hover:bg-gray-50 active:scale-95 transition-all"
                >
                  {if @editing_poi_id, do: "Save", else: "Save draft"}
                </button>
                <%= if not @editing_poi_published do %>
                  <button
                    type="submit"
                    name="publish"
                    value="true"
                    class="flex-1 py-2.5 rounded-xl bg-blue-600 text-white text-sm font-semibold hover:bg-blue-700 active:scale-95 transition-all"
                  >
                    {if @editing_poi_id, do: "Save & Publish", else: "Publish"}
                  </button>
                <% end %>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Geofence creation form (bottom sheet) --%>
      <div
        id="geofence-form-sheet"
        class={[
          "fixed inset-x-0 bottom-0 z-30 transform transition-transform duration-300 ease-out",
          if(@geofence_step == :editing, do: "translate-y-0", else: "translate-y-full")
        ]}
      >
        <div class="bg-white rounded-t-2xl border-t border-gray-200 shadow-2xl max-h-[85vh] flex flex-col">
          <%!-- Sheet header --%>
          <div class="flex items-center justify-between px-5 pt-4 pb-3 border-b border-gray-100">
            <div class="w-10 h-1 bg-gray-200 rounded-full absolute top-2 left-1/2 -translate-x-1/2" />
            <h2 class="text-base font-semibold text-gray-900">
              {if @editing_geofence_id, do: "Edit Geofence", else: "New Geofence"}
            </h2>
            <button
              phx-click="cancel_geofence_form"
              class="w-8 h-8 flex items-center justify-center rounded-full hover:bg-gray-100 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-4 h-4 text-gray-500" />
            </button>
          </div>

          <%!-- Form body --%>
          <div class="flex-1 overflow-y-auto">
            <.form
              for={%{}}
              id="geofence-form"
              phx-change="validate_geofence"
              phx-submit="save_geofence"
              class="px-5 py-4 space-y-4"
            >
              <%!-- Polygon indicator --%>
              <%= if @editing_geofence_id do %>
                <div class="flex items-center gap-2 px-3 py-2 rounded-xl border border-indigo-300 bg-indigo-50 text-sm text-indigo-700">
                  <.icon name="hero-check-circle" class="w-4 h-4 shrink-0" />
                  <span>
                    Existing polygon — {geofence_vertex_count(@geofence_geometry)} vertices
                  </span>
                </div>
              <% else %>
                <div class="flex items-center gap-2 px-3 py-2 rounded-xl border border-indigo-300 bg-indigo-50 text-sm text-indigo-700">
                  <.icon name="hero-check-circle" class="w-4 h-4 shrink-0" />
                  <span>
                    Polygon drawn — {length(@geofence_vertices)} vertices
                  </span>
                  <button
                    type="button"
                    phx-click="cancel_geofence_form"
                    class="ml-auto px-2 py-0.5 rounded-lg border border-indigo-200 text-xs text-indigo-600 hover:bg-indigo-100 transition-colors"
                  >
                    Redraw
                  </button>
                </div>
              <% end %>

              <%!-- Form errors --%>
              <%= if @geofence_errors != [] do %>
                <div class="rounded-xl bg-red-50 border border-red-200 p-3 space-y-1">
                  <%= for {_field, msg} <- @geofence_errors do %>
                    <p class="text-xs text-red-600">{msg}</p>
                  <% end %>
                </div>
              <% end %>

              <%!-- Name --%>
              <div>
                <label for="geofence-name" class="block text-sm font-medium text-gray-700 mb-1">
                  Name <span class="text-red-500">*</span>
                </label>
                <input
                  id="geofence-name"
                  type="text"
                  name="geofence[name]"
                  value={@geofence_name}
                  placeholder="e.g. Base Camp"
                  required
                  class="w-full px-3 py-2 rounded-xl border border-gray-300 bg-white text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-indigo-500/30 focus:border-indigo-500 transition text-sm"
                />
              </div>

              <%!-- Description --%>
              <div>
                <label
                  for="geofence-description"
                  class="block text-sm font-medium text-gray-700 mb-1"
                >
                  Description
                </label>
                <textarea
                  id="geofence-description"
                  name="geofence[description]"
                  rows="2"
                  placeholder="Optional — describe this area…"
                  class="w-full px-3 py-2 rounded-xl border border-gray-300 bg-white text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-indigo-500/30 focus:border-indigo-500 transition text-sm resize-none"
                >{@geofence_description}</textarea>
              </div>

              <%!-- Photos (new geofence only) --%>
              <%= if is_nil(@editing_geofence_id) and @geofence_step == :editing do %>
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
                          <.live_img_preview
                            entry={entry}
                            class="w-16 h-16 object-cover rounded-lg"
                          />
                          <button
                            type="button"
                            phx-click="cancel_upload"
                            phx-value-ref={entry.ref}
                            class="absolute -top-1 -right-1 w-5 h-5 bg-red-500 rounded-full flex items-center justify-center"
                          >
                            <.icon name="hero-x-mark" class="w-3 h-3 text-white" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Purpose (hidden when editing a published geofence) --%>
              <%= if not @editing_geofence_published do %>
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-2">Purpose</label>
                  <div class="grid grid-cols-3 gap-2">
                    <%= for purpose <- @geofence_purposes do %>
                      <label class={[
                        "flex flex-col items-center gap-1 p-2 rounded-xl border cursor-pointer transition-all",
                        if(to_string(purpose) == @geofence_purpose,
                          do: "border-indigo-500 bg-indigo-50 text-indigo-700",
                          else: "border-gray-200 bg-white text-gray-600 hover:border-gray-300"
                        )
                      ]}>
                        <input
                          type="radio"
                          name="geofence[purpose]"
                          value={purpose}
                          checked={to_string(purpose) == @geofence_purpose}
                          class="sr-only"
                        />
                        <.icon
                          name={purpose_icon(purpose)}
                          class={[
                            "w-5 h-5",
                            if(to_string(purpose) == @geofence_purpose,
                              do: "text-indigo-600",
                              else: ""
                            )
                          ]}
                        />
                        <span class="text-xs font-medium capitalize leading-tight text-center">
                          {purpose |> to_string() |> String.replace("_", " ")}
                        </span>
                      </label>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Color --%>
              <div>
                <label for="geofence-color" class="block text-sm font-medium text-gray-700 mb-2">
                  Color
                </label>
                <div class="flex items-center gap-3 flex-wrap">
                  <div class="flex items-center gap-2">
                    <div
                      class="w-8 h-8 rounded-lg border-2 border-white shadow ring-1 ring-gray-200 shrink-0"
                      style={"background-color: #{@geofence_color}"}
                    />
                    <input
                      id="geofence-color"
                      type="color"
                      name="geofence[color]"
                      value={@geofence_color}
                      class="w-10 h-10 rounded-lg border border-gray-300 cursor-pointer p-0.5 bg-white"
                    />
                  </div>
                  <div class="flex gap-1.5 flex-wrap">
                    <%= for {_purpose_key, color} <- @purpose_colors do %>
                      <label
                        class="cursor-pointer"
                        title={color}
                      >
                        <input
                          type="radio"
                          name="geofence[color]"
                          value={color}
                          checked={@geofence_color == color}
                          class="sr-only"
                        />
                        <span
                          class={[
                            "block w-6 h-6 rounded-full border-2 border-white shadow ring-1 transition-transform hover:scale-110 active:scale-95",
                            if(@geofence_color == color,
                              do: "ring-gray-600 scale-110",
                              else: "ring-gray-200"
                            )
                          ]}
                          style={"background-color: #{color}"}
                        />
                      </label>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="flex gap-2 pt-1 pb-2">
                <button
                  type="submit"
                  name="publish"
                  value="false"
                  class="flex-1 py-2.5 rounded-xl border border-gray-300 bg-white text-sm font-semibold text-gray-700 hover:bg-gray-50 active:scale-95 transition-all"
                >
                  {if @editing_geofence_id, do: "Save", else: "Save draft"}
                </button>
                <%= if not @editing_geofence_published do %>
                  <button
                    type="submit"
                    name="publish"
                    value="true"
                    class="flex-1 py-2.5 rounded-xl bg-indigo-600 text-white text-sm font-semibold hover:bg-indigo-700 active:scale-95 transition-all"
                  >
                    {if @editing_geofence_id, do: "Save & Publish", else: "Publish"}
                  </button>
                <% end %>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Map item inspection drawer --%>
      <%= if @selected_map_object do %>
        <% kind = @selected_map_object.kind %>
        <% item = @selected_map_object.item %>
        <div
          id="map-item-drawer"
          class={[
            "fixed z-30 transform transition-all duration-300 ease-in-out",
            "bottom-0 left-0 right-0 md:top-0 md:bottom-0 md:left-auto md:right-0 md:w-96",
            "translate-y-0 md:translate-x-0"
          ]}
        >
          <div class="bg-white rounded-t-2xl border-t border-gray-200 shadow-2xl flex flex-col md:rounded-none md:rounded-l-2xl md:border-l md:border-y md:border-r-0 md:h-full">
            <%!-- Header --%>
            <div class="flex items-start justify-between gap-4 px-5 pt-4 pb-3 border-b border-gray-100 shrink-0">
              <div class="flex items-start gap-3 min-w-0">
                <div class="w-11 h-11 rounded-2xl bg-gray-100 flex items-center justify-center shrink-0">
                  <.icon name={map_item_icon(kind)} class="w-5 h-5 text-gray-600" />
                </div>
                <div class="min-w-0">
                  <p class="text-xs font-semibold uppercase tracking-wide text-gray-500">
                    {MapInspection.kind_label(kind)}
                  </p>
                  <h2 class="text-base font-semibold text-gray-900 truncate">
                    {item.name}
                  </h2>
                </div>
              </div>
              <button
                id="map-item-close-btn"
                phx-click="clear_map_object_inspection"
                class="w-8 h-8 flex items-center justify-center rounded-full hover:bg-gray-100 transition-colors shrink-0"
              >
                <.icon name="hero-x-mark" class="w-4 h-4 text-gray-500" />
              </button>
            </div>

            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <%!-- Status badge + kind-specific chip --%>
              <div class="flex flex-wrap items-center gap-2">
                <span
                  id="map-item-status-badge"
                  class={[
                    "inline-flex items-center px-2.5 py-1 rounded-full text-xs font-semibold",
                    if(MapInspection.resource_status(item) == :published,
                      do: "bg-emerald-50 text-emerald-700",
                      else: "bg-amber-50 text-amber-700"
                    )
                  ]}
                >
                  {MapInspection.status_label(MapInspection.resource_visibility(item))}
                </span>
                <%= if kind == :poi do %>
                  <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-gray-100 text-gray-700 capitalize">
                    <.icon name={category_icon(item.category)} class="w-3 h-3" />
                    {item.category |> to_string() |> String.replace("_", " ")}
                  </span>
                <% else %>
                  <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-gray-100 text-gray-700 capitalize">
                    <span
                      class="w-2 h-2 rounded-full shrink-0"
                      style={"background-color: #{item.color}"}
                    >
                    </span>
                    {item.purpose |> to_string() |> String.replace("_", " ")}
                  </span>
                  <span class="text-xs text-gray-400">
                    {geofence_vertex_count(item.geometry)} pts
                  </span>
                <% end %>
              </div>

              <%!-- Creator + published date --%>
              <%= if is_struct(item.creator, Platser.Accounts.User) do %>
                <p class="text-xs text-gray-400 -mt-1">
                  Added by {item.creator.display_name}
                  <%= if item.published_at do %>
                    · Published {Calendar.strftime(item.published_at, "%d %b %Y")}
                  <% end %>
                </p>
              <% end %>

              <%!-- Description --%>
              <%= if item.description && item.description != "" do %>
                <p class="text-sm text-gray-600 leading-relaxed">{item.description}</p>
              <% end %>

              <%!-- Photo carousel --%>
              <%= if @selected_map_object.attachments != [] do %>
                <div
                  id="map-item-carousel"
                  phx-hook=".Carousel"
                  data-item-key={"#{kind}-#{item.id}"}
                  class="relative rounded-2xl overflow-hidden bg-gray-100"
                >
                  <div data-track class="flex transition-transform duration-300 ease-in-out">
                    <%= for attachment <- @selected_map_object.attachments do %>
                      <div data-slide class="shrink-0 w-full">
                        <a
                          id={"photo-#{attachment.id}"}
                          href={attachment.path}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          <img
                            src={attachment.path}
                            alt={attachment.filename}
                            class="w-full h-52 object-cover"
                          />
                        </a>
                      </div>
                    <% end %>
                  </div>
                  <%= if length(@selected_map_object.attachments) > 1 do %>
                    <button
                      data-prev
                      class="absolute left-2 top-1/2 -translate-y-1/2 w-8 h-8 rounded-full bg-black/40 flex items-center justify-center hover:bg-black/60 transition-colors"
                    >
                      <.icon name="hero-chevron-left" class="w-4 h-4 text-white" />
                    </button>
                    <button
                      data-next
                      class="absolute right-2 top-1/2 -translate-y-1/2 w-8 h-8 rounded-full bg-black/40 flex items-center justify-center hover:bg-black/60 transition-colors"
                    >
                      <.icon name="hero-chevron-right" class="w-4 h-4 text-white" />
                    </button>
                    <div class="absolute bottom-2 left-0 right-0 flex justify-center gap-1.5">
                      <%= for _attachment <- @selected_map_object.attachments do %>
                        <button data-dot class="w-1.5 h-1.5 rounded-full transition-all bg-white/40" />
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Comment --%>
              <%= if @selected_map_object_can_manage do %>
                <div class="rounded-2xl border border-gray-200 bg-gray-50 p-4">
                  <p class="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-2">
                    Comment
                  </p>
                  <textarea
                    id="map-item-comment"
                    name="comment"
                    rows="3"
                    phx-blur="save_map_object_comment"
                    placeholder="Add a comment…"
                    class="w-full resize-none bg-transparent text-sm text-gray-700 leading-relaxed focus:outline-none placeholder:text-gray-400"
                  >{item.comment || ""}</textarea>
                </div>
              <% else %>
                <%= if item.comment && item.comment != "" do %>
                  <div class="rounded-2xl border border-gray-200 bg-gray-50 p-4">
                    <p class="text-xs font-semibold uppercase tracking-wide text-gray-500 mb-2">
                      Comment
                    </p>
                    <p class="text-sm text-gray-600 leading-relaxed">{item.comment}</p>
                  </div>
                <% end %>
              <% end %>
            </div>

            <%!-- Action bar --%>
            <div class="border-t border-gray-100 px-5 py-4 space-y-2 shrink-0">
              <%= if @selected_map_object_can_manage && MapInspection.resource_status(item) == :draft do %>
                <button
                  id="map-item-publish-btn"
                  phx-click="publish_selected_map_object"
                  class="w-full py-2.5 rounded-xl bg-blue-600 text-white text-sm font-semibold hover:bg-blue-700 active:scale-95 transition-all"
                >
                  Publish
                </button>
              <% end %>
              <div class="flex gap-2">
                <button
                  id="map-item-focus-btn"
                  phx-click="focus_selected_map_object"
                  class="flex-1 py-2.5 rounded-xl border border-gray-300 bg-white text-sm font-semibold text-gray-700 hover:bg-gray-50 active:scale-95 transition-all"
                >
                  Focus on map
                </button>
                <%= if @selected_map_object_can_manage do %>
                  <button
                    id="map-item-edit-btn"
                    phx-click="edit_selected_map_object"
                    class="flex-1 py-2.5 rounded-xl border border-gray-300 bg-white text-sm font-semibold text-gray-700 hover:bg-gray-50 active:scale-95 transition-all"
                  >
                    Edit
                  </button>
                  <button
                    id="map-item-delete-btn"
                    phx-click="delete_selected_map_object"
                    class="flex-1 py-2.5 rounded-xl border border-red-200 bg-red-50 text-sm font-semibold text-red-700 hover:bg-red-100 active:scale-95 transition-all"
                  >
                    Delete
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      <% end %>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Carousel">
        export default {
          mounted() {
            this._key = this.el.dataset.itemKey;
            this._idx = 0;
            let startX = 0;
            this.el.addEventListener('touchstart', e => { startX = e.touches[0].clientX; }, { passive: true });
            this.el.addEventListener('touchend', e => {
              const dx = e.changedTouches[0].clientX - startX;
              if (Math.abs(dx) > 40) this._go(dx < 0 ? 1 : -1);
            });
            this._bind();
            this._update();
          },
          updated() {
            const newKey = this.el.dataset.itemKey;
            if (newKey !== this._key) { this._key = newKey; this._idx = 0; }
            this._bind();
            this._update();
          },
          _bind() {
            this._track = this.el.querySelector('[data-track]');
            this._slides = Array.from(this.el.querySelectorAll('[data-slide]'));
            this._dots = Array.from(this.el.querySelectorAll('[data-dot]'));
            const prev = this.el.querySelector('[data-prev]');
            const next = this.el.querySelector('[data-next]');
            if (prev) prev.onclick = () => this._go(-1);
            if (next) next.onclick = () => this._go(1);
            this._dots.forEach((dot, i) => { dot.onclick = () => { this._idx = i; this._update(); }; });
          },
          _go(dir) {
            const count = this._slides.length;
            if (count === 0) return;
            this._idx = (this._idx + dir + count) % count;
            this._update();
          },
          _update() {
            if (this._track) {
              this._track.style.transform = `translateX(-${this._idx * 100}%)`;
            }
            this._dots.forEach((dot, i) => {
              dot.classList.toggle('bg-white', i === this._idx);
              dot.classList.toggle('bg-white/40', i !== this._idx);
            });
          }
        }
      </script>

      <%!-- Activity feed — mobile: slide-up drawer, desktop: right side panel --%>
      <div
        id="activity-drawer"
        class={[
          "fixed z-20 transform transition-all duration-300 ease-in-out",
          "bottom-0 left-0 right-0",
          "md:top-0 md:bottom-0 md:left-auto md:right-0 md:w-80",
          (@poi_step != :idle or @geofence_step != :idle or @selected_map_object) &&
            "opacity-0 pointer-events-none",
          if(@drawer_open,
            do: "translate-y-0 md:translate-x-0",
            else: "translate-y-[calc(100%-3.5rem)] md:translate-y-0 md:translate-x-full"
          )
        ]}
      >
        <div class="bg-white rounded-t-2xl border-t border-gray-200 shadow-2xl flex flex-col md:rounded-none md:rounded-l-2xl md:border-l md:border-y md:border-r-0 md:h-full">
          <%!-- Mobile: drawer handle / toggle button --%>
          <button
            id="drawer-toggle"
            phx-click="toggle_drawer"
            class="w-full py-3 flex flex-col items-center gap-1 focus:outline-none md:hidden"
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

          <%!-- Desktop: panel header --%>
          <div class="hidden md:flex items-center justify-between px-4 py-3 border-b border-gray-100 shrink-0">
            <div class="flex items-center gap-2">
              <.icon name="hero-bell" class="w-4 h-4 text-gray-500" />
              <span class="text-sm font-semibold text-gray-800">Activity</span>
              <%= if @unread_count > 0 do %>
                <span class="inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-blue-600 rounded-full">
                  {if @unread_count > 9, do: "9+", else: @unread_count}
                </span>
              <% end %>
            </div>
            <button
              id="feed-close-desktop"
              phx-click="toggle_drawer"
              class="p-1.5 rounded-lg text-gray-400 hover:text-gray-600 hover:bg-gray-100 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <%!-- Feed entries --%>
          <div
            id="activity-entries"
            phx-update="stream"
            class="px-4 pb-6 pt-2 max-h-72 md:max-h-none md:flex-1 overflow-y-auto"
          >
            <div
              id="activity-entries-empty"
              class="hidden only:block text-center text-sm text-gray-400 py-8"
            >
              No activity yet. Start exploring!
            </div>
            <div
              :for={{id, entry} <- @streams.entries}
              id={id}
              class="activity-entry flex items-start gap-3 py-2.5 border-b border-gray-100 last:border-0"
            >
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

  @spec purpose_icon(atom()) :: String.t()
  defp purpose_icon(:boundary), do: "hero-map"
  defp purpose_icon(:meeting_zone), do: "hero-user-group"
  defp purpose_icon(:restricted), do: "hero-no-symbol"
  defp purpose_icon(:camp_area), do: "hero-home"
  defp purpose_icon(:other), do: "hero-tag"

  @spec ensure_float(number()) :: float()
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0

  @spec maybe_float(number() | nil) :: float() | nil
  defp maybe_float(nil), do: nil
  defp maybe_float(n), do: ensure_float(n)

  @spec validate_bounds(term(), term(), term(), term()) :: :ok | {:error, :invalid_bounds}
  defp validate_bounds(west, south, east, north) do
    with true <- is_number(west) and is_number(south) and is_number(east) and is_number(north),
         true <- Enum.all?([west, south, east, north], &(&1 != :nan and &1 != :infinity)),
         true <- south < north,
         true <- west >= -180 and west <= 180,
         true <- east >= -180 and east <= 180,
         true <- south >= -90 and south <= 90,
         true <- north >= -90 and north <= 90 do
      :ok
    else
      _ -> {:error, :invalid_bounds}
    end
  end

  @spec build_bounds_polygon(number(), number(), number(), number()) :: Geo.Polygon.t()
  defp build_bounds_polygon(west, south, east, north) do
    w = ensure_float(west)
    s = ensure_float(south)
    e = ensure_float(east)
    n = ensure_float(north)

    ring = [{w, s}, {e, s}, {e, n}, {w, n}, {w, s}]
    %Geo.Polygon{coordinates: [ring], srid: 4326}
  end

  @spec bounds_to_map(Geo.Polygon.t() | nil) :: map() | nil
  defp bounds_to_map(nil), do: nil

  defp bounds_to_map(%Geo.Polygon{coordinates: [ring | _]}) do
    lngs = Enum.map(ring, &elem(&1, 0))
    lats = Enum.map(ring, &elem(&1, 1))

    %{
      west: Enum.min(lngs),
      south: Enum.min(lats),
      east: Enum.max(lngs),
      north: Enum.max(lats)
    }
  end
end
