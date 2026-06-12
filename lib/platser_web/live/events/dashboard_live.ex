defmodule PlatserWeb.Events.DashboardLive do
  use PlatserWeb, :live_view

  import Phoenix.Component

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

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Platser.PubSub, "event:#{event.id}:settings")
        end

        socket =
          socket
          |> assign(:page_title, event.name)
          |> assign(:event, event)
          |> assign(:is_admin, is_admin)
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
    actor = socket.assigns.current_user
    event = socket.assigns.event
    allow = val == "true"

    case Events.update_event_settings(event, %{allow_public_comments: allow}, actor: actor) do
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
             |> stream_delete(:memberships, membership)
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
        new_role_atom = String.to_atom(new_role)

        case Events.update_member_role(membership, %{role: new_role_atom}, actor: actor) do
          {:ok, updated_membership} ->
            {:noreply,
             socket
             |> stream_insert(:memberships, updated_membership)
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

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Member not found.")}
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

        <%!-- Event settings (admin only) --%>
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
                <p class="text-sm font-medium text-base-content">Public comments</p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  Allow all event members to write comments on map items.
                </p>
              </div>
              <button
                id="toggle-public-comments-btn"
                phx-click="update_settings"
                phx-value-allow_public_comments={to_string(!@event.allow_public_comments)}
                class={[
                  "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                  if(@event.allow_public_comments,
                    do: "bg-primary",
                    else: "bg-base-300"
                  )
                ]}
                role="switch"
                aria-checked={to_string(@event.allow_public_comments)}
              >
                <span class={[
                  "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow transform transition duration-200 ease-in-out",
                  if(@event.allow_public_comments, do: "translate-x-5", else: "translate-x-0")
                ]} />
              </button>
            </div>
          </section>
        <% end %>

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
              class="flex items-center gap-3 px-5 py-3 group"
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
              <%= if @is_admin do %>
                <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  <%= if membership.role == :admin do %>
                    <button
                      phx-click="update_member_role"
                      phx-value-id={membership.id}
                      phx-value-role="member"
                      title="Demote to Member"
                      class="p-1.5 rounded-lg hover:bg-base-200 text-base-content/60 hover:text-base-content transition-colors"
                      data-confirm="Demote this member to regular member?"
                    >
                      <.icon name="hero-arrow-down" class="w-4 h-4" />
                    </button>
                  <% else %>
                    <button
                      phx-click="update_member_role"
                      phx-value-id={membership.id}
                      phx-value-role="admin"
                      title="Promote to Admin"
                      class="p-1.5 rounded-lg hover:bg-base-200 text-base-content/60 hover:text-base-content transition-colors"
                    >
                      <.icon name="hero-arrow-up" class="w-4 h-4" />
                    </button>
                  <% end %>
                  <button
                    phx-click="remove_member"
                    phx-value-id={membership.id}
                    title="Remove Member"
                    class="p-1.5 rounded-lg hover:bg-red-100 text-base-content/60 hover:text-red-600 transition-colors dark:hover:bg-red-900/20"
                    data-confirm="Remove this member from the event? They can rejoin with the invite code."
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
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
