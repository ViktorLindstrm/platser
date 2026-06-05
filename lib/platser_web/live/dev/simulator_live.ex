defmodule PlatserWeb.Dev.SimulatorLive do
  use PlatserWeb, :live_view

  alias Platser.Accounts.User
  alias Platser.Dev.GpsSimulator
  alias Platser.Events.Event

  @pmtiles_url Application.compile_env(
                 :platser,
                 :pmtiles_url,
                 "pmtiles://https://r2-public.protomaps.com/protomaps-sample-datasets/nz.pmtiles"
               )

  @patterns [:stationary, :linear, :random_walk, :route]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Platser.PubSub, GpsSimulator.topic())

    state = GpsSimulator.get_state()
    events = load_events()

    socket =
      socket
      |> assign(:page_title, "GPS Simulator")
      |> assign(:simulator, state)
      |> assign(:patterns, @patterns)
      |> assign(:pmtiles_url, @pmtiles_url)
      |> assign(:events, events)
      |> assign(
        :form,
        to_form(%{"email" => "", "display_name" => "", "pattern" => "stationary"}, as: :simulator)
      )
      |> assign(:error, nil)

    if connected?(socket), do: send(self(), :push_map_init)

    {:ok, socket}
  end

  @impl true
  def handle_info(:push_map_init, socket) do
    {:noreply, push_map_state(socket, socket.assigns.simulator.users)}
  end

  @impl true
  def handle_info({:simulator_tick, users}, socket) do
    socket =
      socket
      |> assign(simulator: %{socket.assigns.simulator | users: users})
      |> push_map_state(users)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_simulator", _params, socket) do
    if socket.assigns.simulator.running? do
      GpsSimulator.stop_simulation()
      {:noreply, assign(socket, simulator: %{socket.assigns.simulator | running?: false})}
    else
      GpsSimulator.start_simulation()
      {:noreply, assign(socket, simulator: %{socket.assigns.simulator | running?: true})}
    end
  end

  @impl true
  def handle_event("set_event", %{"event_id" => event_id}, socket) do
    event_id = if event_id == "", do: nil, else: event_id
    GpsSimulator.set_event(event_id)
    state = GpsSimulator.get_state()
    {:noreply, assign(socket, simulator: state)}
  end

  @impl true
  def handle_event("validate", %{"simulator" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :simulator))}
  end

  @impl true
  def handle_event("add_user", %{"simulator" => params}, socket) do
    with {:ok, user} <- create_simulated_user(params),
         :ok <-
           GpsSimulator.add_user(
             GpsSimulator,
             user,
             pattern_from(params["pattern"]),
             pattern_opts(params)
           ) do
      {:noreply,
       socket
       |> assign(
         :form,
         to_form(%{"email" => "", "display_name" => "", "pattern" => "stationary"},
           as: :simulator
         )
       )
       |> assign(:simulator, GpsSimulator.get_state())
       |> assign(:error, nil)
       |> put_flash(:info, "Simulated user added")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">GPS Simulator</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Dev-only live location playground for simulated users.
            </p>
          </div>

          <button
            type="button"
            phx-click="toggle_simulator"
            class={[
              "inline-flex items-center gap-2 px-4 py-2 rounded-xl font-semibold text-sm transition-all active:scale-95",
              if(@simulator.running?,
                do: "bg-rose-500 text-white hover:brightness-110",
                else: "bg-emerald-500 text-white hover:brightness-110"
              )
            ]}
          >
            <.icon
              name={if(@simulator.running?, do: "hero-pause", else: "hero-play")}
              class="w-4 h-4"
            />
            {if @simulator.running?, do: "Stop", else: "Start"} simulator
          </button>
        </div>

        <div
          :if={@error}
          class="rounded-xl border border-red-200 bg-red-50 text-red-700 px-4 py-3 text-sm"
        >
          {@error}
        </div>

        <div class="bg-base-100 border border-base-200 rounded-2xl p-5 shadow-sm">
          <div class="flex items-center justify-between gap-3 flex-wrap">
            <h2 class="font-semibold text-base-content">Map</h2>
            <form phx-submit="set_event" id="set-event-form" class="flex items-center gap-2">
              <label class="text-sm text-base-content/50 shrink-0">Event:</label>
              <select
                id="set-event-select"
                name="event_id"
                class="text-sm px-2 py-1 rounded-lg border border-base-300 bg-base-100 text-base-content"
              >
                <option value="">— none —</option>
                <%= for {name, id} <- @events do %>
                  <option value={id} selected={id == @simulator.event_id}>{name}</option>
                <% end %>
              </select>
              <button
                type="submit"
                class="text-sm px-3 py-1 rounded-lg bg-primary text-primary-content font-medium hover:brightness-110 transition-all"
              >
                Set
              </button>
            </form>
          </div>

          <div
            id="simulator-map"
            class="mt-4 relative h-[32rem] rounded-2xl overflow-hidden border border-base-200"
            phx-hook="Map"
            phx-update="ignore"
            data-pmtiles-url={@pmtiles_url}
            data-map-center="59.3293,18.0686"
            data-map-zoom="11"
            data-map-flavor="light"
          />
        </div>

        <div class="grid gap-6">
          <div class="space-y-6">
            <div class="bg-base-100 border border-base-200 rounded-2xl p-5 shadow-sm">
              <h2 class="font-semibold text-base-content">Add simulated user</h2>
              <.form
                for={@form}
                id="simulator-form"
                phx-change="validate"
                phx-submit="add_user"
                class="mt-4 grid gap-4 sm:grid-cols-3"
              >
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  placeholder="sim@example.com"
                  class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100"
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display name"
                  placeholder="Sim User"
                  class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100"
                />
                <.input
                  field={@form[:pattern]}
                  type="select"
                  label="Pattern"
                  options={Enum.map(@patterns, &{Atom.to_string(&1), Atom.to_string(&1)})}
                  class="w-full px-3 py-2 rounded-xl border border-base-300 bg-base-100"
                />
                <div class="sm:col-span-3">
                  <button
                    type="submit"
                    class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-primary text-primary-content font-semibold text-sm hover:brightness-110 transition-all"
                  >
                    <.icon name="hero-user-plus" class="w-4 h-4" /> Add user
                  </button>
                </div>
              </.form>
            </div>

            <div class="bg-base-100 border border-base-200 rounded-2xl p-5 shadow-sm">
              <div class="flex items-center justify-between gap-3">
                <h2 class="font-semibold text-base-content">Simulated users</h2>
                <span class="text-sm text-base-content/50">{length(@simulator.users)} users</span>
              </div>

              <div class="mt-4 overflow-x-auto">
                <table class="min-w-full text-sm">
                  <thead class="text-left text-base-content/50">
                    <tr>
                      <th class="py-2 pr-4">Name</th>
                      <th class="py-2 pr-4">Pattern</th>
                      <th class="py-2 pr-4">Lat</th>
                      <th class="py-2 pr-4">Lng</th>
                      <th class="py-2 pr-4">Presence</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-200">
                    <tr :for={user_state <- @simulator.users}>
                      <td class="py-2 pr-4 font-medium text-base-content">
                        {user_state.user.display_name}
                      </td>
                      <td class="py-2 pr-4 text-base-content/70">
                        {Atom.to_string(user_state.pattern)}
                      </td>
                      <td class="py-2 pr-4 font-mono text-xs">{Float.round(user_state.lat, 5)}</td>
                      <td class="py-2 pr-4 font-mono text-xs">{Float.round(user_state.lng, 5)}</td>
                      <td class="py-2 pr-4">
                        <span class={[
                          "inline-flex items-center px-2 py-1 rounded-full text-xs font-semibold",
                          if(user_state.tracked?,
                            do: "bg-emerald-100 text-emerald-800",
                            else: "bg-base-200 text-base-content/60"
                          )
                        ]}>
                          {if user_state.tracked?, do: "tracked", else: "idle"}
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_events do
    Event
    |> Ash.Query.select([:id, :name])
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.name, &1.id})
  rescue
    _ -> []
  end

  defp create_simulated_user(params) do
    cs =
      User
      |> Ash.Changeset.for_create(:create_simulated, %{
        email: params["email"],
        display_name: params["display_name"]
      })

    case Ash.create(cs, authorize?: false) do
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end

  defp pattern_from(pattern) do
    case pattern do
      "stationary" -> :stationary
      "linear" -> :linear
      "random_walk" -> :random_walk
      "route" -> :route
      _ -> :stationary
    end
  end

  defp pattern_opts(%{"pattern" => "stationary"} = params) do
    base_opts(params) ++ [lat: 59.3293, lng: 18.0686]
  end

  defp pattern_opts(%{"pattern" => "linear"} = params) do
    [start_lat: 59.3293, start_lng: 18.0686, end_lat: 59.3393, end_lng: 18.0786, total_steps: 20] ++
      base_opts(params)
  end

  defp pattern_opts(%{"pattern" => "random_walk"} = params) do
    base_opts(params) ++ [step_size: 0.0015]
  end

  defp pattern_opts(%{"pattern" => "route"} = params) do
    base_opts(params) ++ [radius: 0.002]
  end

  defp base_opts(_params), do: []

  defp error_message(error), do: inspect(error)

  defp push_map_state(socket, users) do
    member_locations =
      Enum.map(users, fn user_state ->
        %{
          user_id: user_state.user.id,
          lat: user_state.lat,
          lng: user_state.lng,
          display_name: user_state.user.display_name,
          is_simulated: user_state.user.is_simulated
        }
      end)

    socket
    |> push_event("map_init", %{pois: empty_collection(), geofences: empty_collection()})
    |> push_event("member_locations_init", %{locations: member_locations})
  end

  defp empty_collection do
    %{type: "FeatureCollection", features: []}
  end
end
