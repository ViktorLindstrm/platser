defmodule PlatserWeb.Events.DashboardLive do
  use PlatserWeb, :live_view

  import Phoenix.Component

  alias Platser.Events
  alias Platser.Events.Event
  alias Platser.Events.MapAccess
  alias Platser.Events.Membership
  alias Platser.Events.ParticipationSettings
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
        is_admin = full_manager?(memberships, actor.id)
        member_stats = member_stats(memberships, pois, geofences)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event.id}:settings")
        end

        socket =
          socket
          |> assign(:page_title, event.name)
          |> assign(:event, event)
          |> assign(:is_admin, is_admin)
          |> assign(:member_stats, member_stats)
          |> assign(:editing, false)
          |> assign(:event_form, nil)
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
  def handle_info({:event_updated, event}, socket) do
    {:noreply,
     socket
     |> assign(:event, event)
     |> assign(:page_title, event.name)
     |> put_flash(:info, "Event updated.")}
  end

  def handle_info({:event_settings_updated, event}, socket) do
    {:noreply, assign(socket, :event, event)}
  end

  @impl Phoenix.LiveView
  def handle_event("edit_event", _params, socket) do
    event = socket.assigns.event
    actor = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_update(event, :update,
        actor: actor,
        as: "event",
        domain: Platser.Events
      )

    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign(:event_form, to_form(form))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:event_form, nil)}
  end

  def handle_event("save_event", %{"event" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.event_form.source, params: params) do
      {:ok, updated_event} ->
        {:noreply,
         socket
         |> assign(:event, updated_event)
         |> assign(:page_title, updated_event.name)
         |> assign(:editing, false)
         |> assign(:event_form, nil)
         |> put_flash(:info, "Event updated successfully.")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:event_form, to_form(form))
         |> put_flash(:error, "Could not update event.")}
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

  def handle_event("invalidate_code", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    case Events.invalidate_event_join_code(event, actor: actor) do
      {:ok, updated_event} ->
        {:noreply,
         socket
         |> assign(:event, updated_event)
         |> put_flash(:info, "Invite code invalidated. Existing members keep access.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not invalidate invite code.")}
    end
  end

  def handle_event("update_settings", %{"allow_public_comments" => val}, socket) do
    handle_event("update_settings", %{"allow_participant_comments" => val}, socket)
  end

  def handle_event("update_settings", %{"allow_participant_comments" => val}, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    with {:ok, allow} <- ParticipationSettings.parse_boolean(val),
         {:ok, updated_event} <-
           Events.update_event_settings(event, %{allow_participant_comments: allow}, actor: actor) do
      Phoenix.PubSub.broadcast(
        Platser.PubSub,
        "event:#{event.id}:settings",
        {:event_settings_updated, updated_event}
      )

      {:noreply,
       socket
       |> assign(:event, updated_event)
       |> put_flash(:info, "Settings saved.")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
    end
  end

  def handle_event("update_settings", params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    setting_attrs =
      params
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, attrs} ->
        with {:ok, setting} <- ParticipationSettings.parse_setting(key),
             {:ok, allow?} <- ParticipationSettings.parse_boolean(value) do
          attr =
            case setting do
              :comments -> :allow_participant_comments
              :check_ins -> :allow_participant_check_ins
              :live_location -> :allow_participant_live_location
            end

          {:cont, {:ok, Map.put(attrs, attr, allow?)}}
        else
          :error -> {:halt, :error}
        end
      end)

    case setting_attrs do
      {:ok, attrs} when map_size(attrs) > 0 ->
        case Events.update_event_settings(event, attrs, actor: actor) do
          {:ok, updated_event} ->
            Phoenix.PubSub.broadcast(
              Platser.PubSub,
              "event:#{event.id}:settings",
              {:event_settings_updated, updated_event}
            )

            {:noreply,
             socket
             |> assign(:event, updated_event)
             |> put_flash(:info, "Settings saved.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save settings.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
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

  def handle_event("remove_member", %{"id" => membership_id}, socket) do
    actor = socket.assigns.current_user

    case Ash.get(Membership, membership_id, actor: actor) do
      {:ok, membership} ->
        case Events.remove_member(membership, actor: actor) do
          :ok ->
            {:noreply,
             socket
             |> refresh_membership_stream()
             |> put_flash(:info, "Member removed from event.")}

          {:error, %Ash.Error.Forbidden{}} ->
            {:noreply, put_flash(socket, :error, "You do not have permission to remove members.")}

          {:error, %Ash.Error.Invalid{} = err} ->
            message = format_error(err)
            {:noreply, put_flash(socket, :error, message)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove member.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Member not found.")}
    end
  end

  def handle_event("update_member_role", %{"id" => membership_id, "role" => new_role}, socket) do
    actor = socket.assigns.current_user

    case Ash.get(Membership, membership_id, actor: actor) do
      {:ok, membership} ->
        case MapAccess.parse_role(new_role) do
          {:ok, role} ->
            update_member_role(socket, membership, role, actor)

          :error ->
            {:noreply, put_flash(socket, :error, "Could not update member role.")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Member not found.")}
    end
  end

  @spec update_member_role(
          Phoenix.LiveView.Socket.t(),
          Membership.t(),
          MapAccess.role(),
          Platser.Accounts.User.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp update_member_role(socket, membership, role, actor) do
    case Events.update_member_role(membership, %{role: role}, actor: actor) do
      {:ok, updated_membership} ->
        {:noreply,
         socket
         |> refresh_membership_stream(updated_membership)
         |> put_flash(:info, "Member role updated.")}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to update member roles.")}

      {:error, %Ash.Error.Invalid{} = err} ->
        message = format_error(err)
        {:noreply, put_flash(socket, :error, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update member role.")}
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
          <div class="flex items-center gap-2">
            <%= if @is_admin do %>
              <button
                id="edit-event-btn"
                phx-click="edit_event"
                class="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl bg-base-200 text-base-content/70 text-sm font-semibold hover:bg-base-300 active:scale-95 transition-all"
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" /> Edit
              </button>
            <% end %>
            <.link
              navigate={~p"/events/#{@event.id}/map"}
              class="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold hover:brightness-110 active:scale-95 transition-all"
            >
              <.icon name="hero-map" class="w-4 h-4" /> Open Map
            </.link>
          </div>
        </div>

        <%!-- Edit event modal --%>
        <%= if @editing do %>
          <div
            id="edit-event-modal"
            phx-hook=".EditEventModal"
            class="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4"
            phx-click="cancel_edit"
          >
            <div class="bg-base-100 rounded-2xl shadow-xl max-w-md w-full p-6 space-y-4">
              <h2 class="text-xl font-bold text-base-content">Edit Event</h2>
              <.form
                for={@event_form}
                id="edit-event-form"
                phx-submit="save_event"
                class="space-y-4"
              >
                <.input
                  field={@event_form[:name]}
                  type="text"
                  label="Event name"
                  placeholder="Enter event name"
                  required
                />
                <.input
                  field={@event_form[:description]}
                  type="textarea"
                  label="Description"
                  placeholder="Enter event description (optional)"
                  phx-debounce="300"
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@event_form[:starts_at]}
                    type="datetime-local"
                    label="Starts at"
                    required
                  />
                  <.input
                    field={@event_form[:ends_at]}
                    type="datetime-local"
                    label="Ends at"
                    required
                  />
                </div>
                <div class="flex gap-2 pt-2">
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="flex-1 px-4 py-2.5 rounded-xl bg-base-200 text-base-content/70 font-medium hover:bg-base-300 transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="flex-1 px-4 py-2.5 rounded-xl bg-primary text-primary-content font-medium hover:brightness-110 active:scale-95 transition-all"
                  >
                    Save Changes
                  </button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

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
              class={[
                "flex-1 bg-base-200 rounded-xl px-5 py-3 font-mono text-3xl font-bold tracking-widest text-center border border-base-300 select-all",
                if(active_join_code?(@event),
                  do: "text-base-content",
                  else: "text-base-content/40 line-through"
                )
              ]}
            >
              {@event.join_code}
            </div>
            <%= if active_join_code?(@event) do %>
              <button
                id="copy-invite-link-btn"
                phx-hook=".CopyInviteLink"
                data-join-code={@event.join_code}
                class="p-3 rounded-xl bg-primary text-primary-content border border-primary hover:brightness-110 transition-all active:scale-95 duration-200"
                title="Copy invite link to clipboard"
              >
                <.icon name="hero-link" class="w-5 h-5" />
              </button>
            <% end %>
            <%= if @is_admin do %>
              <button
                id="regenerate-code-btn"
                phx-click="regenerate_code"
                class="p-3 rounded-xl bg-base-100 border border-base-200 hover:bg-base-200 transition-colors text-base-content/60 hover:text-base-content"
                title="Regenerate invite code"
              >
                <.icon name="hero-arrow-path" class="w-5 h-5" />
              </button>
              <%= if active_join_code?(@event) do %>
                <button
                  id="invalidate-code-btn"
                  phx-click="invalidate_code"
                  class="p-3 rounded-xl bg-base-100 border border-red-200 hover:bg-red-50 transition-colors text-red-500 hover:text-red-600 dark:border-red-900/40 dark:hover:bg-red-900/20"
                  title="Invalidate invite code"
                  data-confirm="Invalidate this invite code? Existing members keep access, but new participants will need a regenerated code."
                >
                  <.icon name="hero-no-symbol" class="w-5 h-5" />
                </button>
              <% end %>
            <% end %>
          </div>
          <p class="text-xs text-base-content/40">
            <%= cond do %>
              <% not active_join_code?(@event) -> %>
                This invite code is inactive. Regenerate it to allow new participants to join.
              <% @is_admin -> %>
                Share this code with participants. They can join at <strong class="font-medium text-base-content/60">/join/{@event.join_code}</strong>.
                Regenerating or invalidating disables the old code; existing members keep access.
              <% true -> %>
                Share this code with participants. They can join at <strong class="font-medium text-base-content/60">/join/{@event.join_code}</strong>.
            <% end %>
          </p>
          <dl class="grid gap-2 text-xs text-base-content/50 sm:grid-cols-3">
            <div>
              <dt class="font-semibold text-base-content/60">Expires</dt>
              <dd>{Calendar.strftime(@event.join_code_expires_at, "%b %-d, %Y %H:%M")} UTC</dd>
            </div>
            <div>
              <dt class="font-semibold text-base-content/60">Rotated</dt>
              <dd>{Calendar.strftime(@event.join_code_rotated_at, "%b %-d, %Y %H:%M")} UTC</dd>
            </div>
            <div>
              <dt class="font-semibold text-base-content/60">Status</dt>
              <dd>{join_code_status(@event)}</dd>
            </div>
          </dl>
        </section>

        <%!-- Event settings (map manager only) --%>
        <%= if @is_admin do %>
          <section
            id="event-settings-section"
            class="bg-base-100 border border-base-200 rounded-2xl p-6 space-y-4"
          >
            <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider">
              Settings
            </h2>
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-sm font-medium text-base-content">Member comments</p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  Allow all event members to write comments on map items.
                </p>
              </div>
              <button
                id="toggle-member-comments-btn"
                phx-click="update_settings"
                phx-value-allow_participant_comments={to_string(!@event.allow_participant_comments)}
                class={[
                  "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                  if(@event.allow_participant_comments,
                    do: "bg-primary",
                    else: "bg-base-300"
                  )
                ]}
                role="switch"
                aria-checked={to_string(@event.allow_participant_comments)}
              >
                <span class={[
                  "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow transform transition duration-200 ease-in-out",
                  if(@event.allow_participant_comments, do: "translate-x-5", else: "translate-x-0")
                ]} />
              </button>
            </div>
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-sm font-medium text-base-content">Member check-ins</p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  Allow event members to create one-off location check-ins.
                </p>
              </div>
              <button
                id="toggle-member-check-ins-btn"
                phx-click="update_settings"
                phx-value-check_ins={to_string(!@event.allow_participant_check_ins)}
                class={[
                  "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                  if(@event.allow_participant_check_ins, do: "bg-primary", else: "bg-base-300")
                ]}
                role="switch"
                aria-checked={to_string(@event.allow_participant_check_ins)}
              >
                <span class={[
                  "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow transform transition duration-200 ease-in-out",
                  if(@event.allow_participant_check_ins, do: "translate-x-5", else: "translate-x-0")
                ]} />
              </button>
            </div>
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-sm font-medium text-base-content">Member live location</p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  Allow event members to share live location while viewing the map.
                </p>
              </div>
              <button
                id="toggle-member-live-location-btn"
                phx-click="update_settings"
                phx-value-live_location={to_string(!@event.allow_participant_live_location)}
                class={[
                  "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                  if(@event.allow_participant_live_location, do: "bg-primary", else: "bg-base-300")
                ]}
                role="switch"
                aria-checked={to_string(@event.allow_participant_live_location)}
              >
                <span class={[
                  "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow transform transition duration-200 ease-in-out",
                  if(@event.allow_participant_live_location,
                    do: "translate-x-5",
                    else: "translate-x-0"
                  )
                ]} />
              </button>
            </div>
          </section>
        <% end %>

        <%!-- Members section --%>
        <section id="members-section" class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 class="text-lg font-semibold text-base-content">
                Members
              </h2>
              <p class="mt-1 text-sm text-base-content/50">
                Review map access, account type, join state, and contribution status.
              </p>
            </div>
            <dl
              id="member-management-summary"
              class="grid grid-cols-3 gap-2 rounded-2xl border border-base-200 bg-base-100 p-2 text-center sm:min-w-80"
            >
              <div class="rounded-xl bg-base-200/70 px-3 py-2">
                <dt class="text-[11px] font-semibold uppercase text-base-content/45">Members</dt>
                <dd class="text-lg font-bold text-base-content">{@member_stats.total}</dd>
              </div>
              <div class="rounded-xl bg-amber-50 px-3 py-2 dark:bg-amber-900/20">
                <dt class="text-[11px] font-semibold uppercase text-amber-700/70 dark:text-amber-300/70">
                  Managers
                </dt>
                <dd class="text-lg font-bold text-amber-700 dark:text-amber-300">
                  {@member_stats.full_managers}
                </dd>
              </div>
              <div class="rounded-xl bg-emerald-50 px-3 py-2 dark:bg-emerald-900/20">
                <dt class="text-[11px] font-semibold uppercase text-emerald-700/70 dark:text-emerald-300/70">
                  Active
                </dt>
                <dd class="text-lg font-bold text-emerald-700 dark:text-emerald-300">
                  {@member_stats.contributors}
                </dd>
              </div>
            </dl>
          </div>
          <div
            id="memberships-list"
            phx-update="stream"
            class="bg-base-100 border border-base-200 rounded-2xl divide-y divide-base-200 overflow-hidden"
          >
            <div
              :for={{id, membership} <- @streams.memberships}
              id={id}
              class="grid gap-4 px-5 py-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center"
            >
              <% summary = member_summary(@member_stats, membership) %>
              <% sole_full_manager? = sole_full_manager?(@member_stats, membership) %>
              <div class="flex min-w-0 gap-3">
                <div class="w-11 h-11 rounded-2xl bg-primary/10 flex items-center justify-center shrink-0">
                  <span class="text-sm font-bold text-primary uppercase">
                    {member_initial(membership.user.display_name)}
                  </span>
                </div>
                <div class="min-w-0 flex-1 space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-base-content truncate">
                      {membership.user.display_name}
                    </p>
                    <span
                      id={"member-account-status-#{membership.id}"}
                      class={[
                        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-semibold",
                        if(membership.user.is_guest,
                          do:
                            "bg-sky-50 text-sky-700 ring-1 ring-sky-100 dark:bg-sky-900/20 dark:text-sky-300 dark:ring-sky-900/40",
                          else:
                            "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-100 dark:bg-emerald-900/20 dark:text-emerald-300 dark:ring-emerald-900/40"
                        )
                      ]}
                    >
                      <.icon
                        name={if membership.user.is_guest, do: "hero-user", else: "hero-shield-check"}
                        class="w-3 h-3"
                      />
                      {if membership.user.is_guest, do: "Guest", else: "Registered"}
                    </span>
                    <%= if membership.user_id == @current_user.id do %>
                      <span
                        id={"member-current-user-#{membership.id}"}
                        class="rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-semibold text-base-content/60"
                      >
                        You
                      </span>
                    <% end %>
                  </div>
                  <div class="flex flex-wrap items-center gap-2">
                    <span
                      id={"member-access-level-#{membership.id}"}
                      class={[
                        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold",
                        role_badge_class(membership.role)
                      ]}
                    >
                      <.icon name={role_icon(membership.role)} class="w-3.5 h-3.5" />
                      {MapAccess.label(membership.role)}
                    </span>
                    <span
                      id={"member-contribution-status-#{membership.id}"}
                      class={[
                        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold",
                        contribution_badge_class(summary.total_contributions)
                      ]}
                    >
                      <.icon name="hero-map-pin" class="w-3.5 h-3.5" />
                      {contribution_label(summary)}
                    </span>
                    <span
                      id={"member-join-state-#{membership.id}"}
                      class="inline-flex items-center gap-1 rounded-full bg-base-200 px-2.5 py-1 text-xs font-semibold text-base-content/60"
                    >
                      <.icon name="hero-calendar-days" class="w-3.5 h-3.5" />
                      Joined {Calendar.strftime(membership.joined_at, "%b %-d, %Y")}
                    </span>
                    <span
                      id={"member-participation-status-#{membership.id}"}
                      class={[
                        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold",
                        participation_badge_class(@event)
                      ]}
                    >
                      <.icon name={participation_icon(@event)} class="w-3.5 h-3.5" />
                      {participation_label(@event, membership)}
                    </span>
                  </div>
                </div>
              </div>
              <%= if @is_admin do %>
                <div
                  id={"member-controls-#{membership.id}"}
                  class="flex flex-wrap items-center gap-2 lg:justify-end"
                >
                  <%= if MapAccess.normalize(membership.role) != :full_manager do %>
                    <button
                      id={"promote-full-manager-#{membership.id}"}
                      phx-click="update_member_role"
                      phx-value-id={membership.id}
                      phx-value-role="full_manager"
                      title={
                        if membership.user.is_guest,
                          do: "Guests must register before becoming map managers",
                          else: "Promote to Map manager"
                      }
                      disabled={membership.user.is_guest}
                      class={[
                        "inline-flex h-9 items-center gap-1.5 rounded-xl px-3 text-xs font-semibold transition-all",
                        if(membership.user.is_guest,
                          do: "cursor-not-allowed bg-base-200 text-base-content/30",
                          else:
                            "bg-amber-50 text-amber-700 hover:bg-amber-100 active:scale-95 dark:bg-amber-900/20 dark:text-amber-300"
                        )
                      ]}
                    >
                      <.icon name="hero-arrow-up" class="w-4 h-4" /> Map manager
                    </button>
                  <% end %>
                  <%= if MapAccess.normalize(membership.role) != :content_manager do %>
                    <button
                      id={"promote-content-manager-#{membership.id}"}
                      phx-click="update_member_role"
                      phx-value-id={membership.id}
                      phx-value-role="content_manager"
                      title={
                        if membership.user.is_guest,
                          do: "Guests must register before becoming contributor managers",
                          else: "Set as Contributor manager"
                      }
                      disabled={membership.user.is_guest}
                      class={[
                        "inline-flex h-9 items-center gap-1.5 rounded-xl px-3 text-xs font-semibold transition-all",
                        if(membership.user.is_guest,
                          do: "cursor-not-allowed bg-base-200 text-base-content/30",
                          else:
                            "bg-indigo-50 text-indigo-700 hover:bg-indigo-100 active:scale-95 dark:bg-indigo-900/20 dark:text-indigo-300"
                        )
                      ]}
                    >
                      <.icon name="hero-pencil-square" class="w-4 h-4" /> Contributor
                    </button>
                  <% end %>
                  <%= if MapAccess.normalize(membership.role) != :participant do %>
                    <button
                      id={"demote-participant-#{membership.id}"}
                      phx-click="update_member_role"
                      phx-value-id={membership.id}
                      phx-value-role="participant"
                      title={
                        if sole_full_manager?,
                          do: "The event needs at least one map manager",
                          else: "Set as Member"
                      }
                      disabled={sole_full_manager?}
                      class={[
                        "inline-flex h-9 items-center gap-1.5 rounded-xl px-3 text-xs font-semibold transition-all",
                        if(sole_full_manager?,
                          do: "cursor-not-allowed bg-base-200 text-base-content/30",
                          else: "bg-base-200 text-base-content/70 hover:bg-base-300 active:scale-95"
                        )
                      ]}
                      data-confirm="Change this member to normal member access?"
                    >
                      <.icon name="hero-arrow-down" class="w-4 h-4" /> Member
                    </button>
                  <% end %>
                  <button
                    id={"remove-member-#{membership.id}"}
                    phx-click="remove_member"
                    phx-value-id={membership.id}
                    title={
                      if sole_full_manager?,
                        do: "The event needs at least one map manager",
                        else: "Remove Member"
                    }
                    disabled={sole_full_manager?}
                    class={[
                      "inline-flex h-9 items-center gap-1.5 rounded-xl px-3 text-xs font-semibold transition-all",
                      if(sole_full_manager?,
                        do: "cursor-not-allowed bg-base-200 text-base-content/30",
                        else:
                          "bg-red-50 text-red-600 hover:bg-red-100 active:scale-95 dark:bg-red-900/20 dark:text-red-300"
                      )
                    ]}
                    data-confirm="Remove this member from the event? They can rejoin with the invite code."
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" /> Remove
                  </button>
                </div>
              <% end %>
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
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyInviteLink">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            const code = this.el.dataset.joinCode;
            const url = window.location.origin + "/join/" + code;
            try {
              await navigator.clipboard.writeText(url);
              const originalHtml = this.el.innerHTML;
              const originalClass = this.el.className;
              this.el.innerHTML = '<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/></svg>';
              this.el.className = originalClass.replace("bg-primary", "bg-success").replace("hover:brightness-110", "");
              setTimeout(() => {
                this.el.innerHTML = originalHtml;
                this.el.className = originalClass;
              }, 2000);
            } catch (err) {
              console.error("Failed to copy to clipboard:", err);
            }
          });
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".EditEventModal">
      export default {
        mounted() {
          const modal = this.el;
          const content = modal.querySelector('[id="edit-event-form"]')?.parentElement;
          if (content) {
            content.addEventListener("click", e => e.stopPropagation());
          }
        }
      }
    </script>
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

  @type member_summary :: %{
          poi_count: non_neg_integer(),
          geofence_count: non_neg_integer(),
          total_contributions: non_neg_integer()
        }

  @type member_stats :: %{
          total: non_neg_integer(),
          full_managers: non_neg_integer(),
          contributors: non_neg_integer(),
          summaries: %{optional(Ecto.UUID.t()) => member_summary()}
        }

  @spec refresh_membership_stream(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_membership_stream(socket) do
    refresh_membership_stream(socket, nil)
  end

  @spec refresh_membership_stream(Phoenix.LiveView.Socket.t(), Membership.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp refresh_membership_stream(socket, _updated_membership) do
    actor = socket.assigns.current_user
    event_id = socket.assigns.event.id
    memberships = load_memberships(event_id, actor)
    pois = load_pois(event_id, actor)
    geofences = load_geofences(event_id, actor)
    member_stats = member_stats(memberships, pois, geofences)

    socket
    |> assign(:member_stats, member_stats)
    |> assign(:is_admin, full_manager?(memberships, actor.id))
    |> stream(:memberships, memberships, reset: true)
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

  @spec member_stats([Membership.t()], [Poi.t()], [Geofence.t()]) :: member_stats()
  defp member_stats(memberships, pois, geofences) do
    summaries =
      Map.new(memberships, fn membership ->
        poi_count = Enum.count(pois, &(&1.creator_id == membership.user_id))
        geofence_count = Enum.count(geofences, &(&1.creator_id == membership.user_id))

        {membership.id,
         %{
           poi_count: poi_count,
           geofence_count: geofence_count,
           total_contributions: poi_count + geofence_count
         }}
      end)

    %{
      total: length(memberships),
      full_managers: Enum.count(memberships, &MapAccess.full_manager?(&1.role)),
      contributors:
        Enum.count(memberships, fn membership ->
          summary = Map.fetch!(summaries, membership.id)
          summary.total_contributions > 0 or MapAccess.manager?(membership.role)
        end),
      summaries: summaries
    }
  end

  @spec member_summary(member_stats(), Membership.t()) :: member_summary()
  defp member_summary(member_stats, membership) do
    Map.get(member_stats.summaries, membership.id, %{
      poi_count: 0,
      geofence_count: 0,
      total_contributions: 0
    })
  end

  @spec sole_full_manager?(member_stats(), Membership.t()) :: boolean()
  defp sole_full_manager?(member_stats, membership) do
    MapAccess.full_manager?(membership.role) and member_stats.full_managers <= 1
  end

  @spec member_initial(String.t()) :: String.t()
  defp member_initial(display_name) do
    display_name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      initial -> initial
    end
  end

  @spec role_icon(MapAccess.compatible_role()) :: String.t()
  defp role_icon(role) do
    case MapAccess.normalize(role) do
      :full_manager -> "hero-shield-check"
      :content_manager -> "hero-pencil-square"
      :participant -> "hero-user"
    end
  end

  @spec role_badge_class(MapAccess.compatible_role()) :: String.t()
  defp role_badge_class(role) do
    case MapAccess.normalize(role) do
      :full_manager ->
        "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"

      :content_manager ->
        "bg-indigo-100 text-indigo-800 dark:bg-indigo-900/30 dark:text-indigo-300"

      :participant ->
        "bg-base-200 text-base-content/60"
    end
  end

  @spec contribution_label(member_summary()) :: String.t()
  defp contribution_label(%{total_contributions: 0}), do: "No map items yet"

  defp contribution_label(summary) do
    "#{summary.total_contributions} item#{plural(summary.total_contributions)} · #{summary.poi_count} POI#{plural(summary.poi_count)} · #{summary.geofence_count} area#{plural(summary.geofence_count)}"
  end

  @spec contribution_badge_class(non_neg_integer()) :: String.t()
  defp contribution_badge_class(0), do: "bg-base-200 text-base-content/55"

  defp contribution_badge_class(_count),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/20 dark:text-emerald-300"

  @spec participation_label(Event.t(), Membership.t()) :: String.t()
  defp participation_label(event, membership) do
    if MapAccess.manager?(membership.role) do
      "Manager contribution"
    else
      disabled_count =
        [
          event.allow_participant_comments,
          event.allow_participant_check_ins,
          event.allow_participant_live_location
        ]
        |> Enum.count(&(&1 == false))

      case disabled_count do
        0 -> "Contributor"
        3 -> "Restricted viewer"
        _ -> "Partly restricted"
      end
    end
  end

  @spec participation_icon(Event.t()) :: String.t()
  defp participation_icon(event) do
    if event.allow_participant_comments and event.allow_participant_check_ins and
         event.allow_participant_live_location do
      "hero-check-circle"
    else
      "hero-eye"
    end
  end

  @spec participation_badge_class(Event.t()) :: String.t()
  defp participation_badge_class(event) do
    if event.allow_participant_comments and event.allow_participant_check_ins and
         event.allow_participant_live_location do
      "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/20 dark:text-emerald-300"
    else
      "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300"
    end
  end

  @spec plural(non_neg_integer()) :: String.t()
  defp plural(1), do: ""
  defp plural(_count), do: "s"

  @spec full_manager?([Membership.t()], Ecto.UUID.t()) :: boolean()
  defp full_manager?(memberships, user_id) do
    Enum.any?(memberships, &(&1.user_id == user_id and MapAccess.full_manager?(&1.role)))
  end

  @spec active_join_code?(Event.t()) :: boolean()
  defp active_join_code?(event) do
    is_nil(event.join_code_invalidated_at) and
      DateTime.compare(event.join_code_expires_at, DateTime.utc_now()) == :gt
  end

  @spec join_code_status(Event.t()) :: String.t()
  defp join_code_status(event) do
    cond do
      not is_nil(event.join_code_invalidated_at) -> "Invalidated"
      DateTime.compare(event.join_code_expires_at, DateTime.utc_now()) != :gt -> "Expired"
      true -> "Active"
    end
  end

  @spec format_error(Ash.Error.Invalid.t()) :: String.t()
  defp format_error(%Ash.Error.Invalid{} = error) do
    error.errors
    |> Enum.map_join(", ", fn e -> Map.get(e, :message, "unknown error") end)
  end
end
