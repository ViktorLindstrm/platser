defmodule PlatserWeb.Admin.DashboardLive do
  @moduledoc """
  Administrator dashboard LiveView.

  Displays platform usage statistics, historical trends, error logs, and
  VM performance metrics. Accessible only to users with `superuser: true`
  via the `:ensure_superuser` on_mount guard.

  Refreshes automatically every 30 seconds.
  """

  use PlatserWeb, :live_view

  alias Platser.Admin.ErrorBuffer
  alias Platser.Admin.Stats

  @live_dashboard_path if Application.compile_env(:platser, :dev_routes, false),
                         do: "/dev/dashboard",
                         else: "/admin/live_dashboard"

  @refresh_interval_ms 30_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    {:ok, socket |> assign(:live_dashboard_path, @live_dashboard_path) |> load_all_stats()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_all_stats(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_errors", _params, socket) do
    ErrorBuffer.clear()
    {:noreply, assign(socket, :error_groups, [])}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_detail", %{"key" => key}, socket) do
    if socket.assigns.detail_key == key do
      {:noreply, assign(socket, detail_key: nil, detail_data: [])}
    else
      {:noreply,
       socket
       |> assign(:detail_key, key)
       |> assign(:detail_data, Stats.detail_rows(key))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_error_group", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded_error_keys

    expanded =
      if MapSet.member?(expanded, key) do
        MapSet.delete(expanded, key)
      else
        MapSet.put(expanded, key)
      end

    {:noreply, assign(socket, :expanded_error_keys, expanded)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_user} full_width={true}>
      <div
        id="admin-dashboard"
        phx-hook=".ForceDark"
        class="min-h-[calc(100vh-3.5rem)] bg-gray-950 text-gray-100"
      >
        <%!-- Header --%>
        <div class="border-b border-gray-800 bg-gray-900/60 backdrop-blur-sm sticky top-0 z-10">
          <div class="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="w-8 h-8 rounded-lg bg-indigo-500/20 border border-indigo-500/30 flex items-center justify-center">
                <.icon name="hero-chart-bar" class="w-4 h-4 text-indigo-400" />
              </div>
              <div>
                <h1 class="text-lg font-semibold text-white">Admin Dashboard</h1>
                <p class="text-xs text-gray-500">Platform overview · auto-refreshes every 30s</p>
              </div>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-500">
                Last updated: {Calendar.strftime(@last_updated, "%H:%M:%S")}
              </span>
              <a
                href={@live_dashboard_path}
                class="flex items-center gap-1.5 text-xs text-indigo-400 hover:text-indigo-300 transition-colors border border-indigo-500/30 rounded-lg px-3 py-1.5 hover:bg-indigo-500/10"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" /> LiveDashboard
              </a>
            </div>
          </div>
        </div>

        <div class="max-w-7xl mx-auto px-6 py-8 space-y-10">
          <%!-- Current Usage Section --%>
          <section>
            <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-500 mb-4">
              Current Activity
            </h2>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <.stat_card
                label="Active Processes"
                value={@stats.vm.process_count}
                icon="hero-cpu-chip"
                color="indigo"
              />
              <.stat_card
                label="Recent Activity (1h)"
                value={@stats.recent_activity}
                icon="hero-bolt"
                color="amber"
              />
              <.stat_card
                label="Retention Runs"
                value={@stats.retention_runs}
                icon="hero-shield-check"
                color="teal"
                subtitle={retention_subtitle(@stats.retention)}
                click_key="retention_runs"
                selected={@detail_key == "retention_runs"}
              />
              <.stat_card
                label="Run Queue"
                value={@stats.vm.run_queue}
                icon="hero-queue-list"
                color="emerald"
                subtitle="schedulers"
              />
            </div>
          </section>

          <%!-- Overall Usage Section --%>
          <section>
            <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-500 mb-4">
              Platform Totals
            </h2>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <.stat_card
                label="Total Users"
                value={@stats.users}
                icon="hero-users"
                color="blue"
                subtitle={"#{@stats.guests} guests"}
                click_key="users"
                selected={@detail_key == "users"}
              />
              <.stat_card
                label="Registered"
                value={@stats.registered}
                icon="hero-user-check"
                color="green"
                click_key="registered"
                selected={@detail_key == "registered"}
              />
              <.stat_card
                label="Events"
                value={@stats.events}
                icon="hero-calendar"
                color="purple"
                click_key="events"
                selected={@detail_key == "events"}
              />
              <.stat_card
                label="Memberships"
                value={@stats.memberships}
                icon="hero-user-group"
                color="cyan"
                click_key="memberships"
                selected={@detail_key == "memberships"}
              />
              <.stat_card
                label="POIs"
                value={@stats.pois}
                icon="hero-map-pin"
                color="rose"
                click_key="pois"
                selected={@detail_key == "pois"}
              />
              <.stat_card
                label="Geofences"
                value={@stats.geofences}
                icon="hero-map"
                color="orange"
                click_key="geofences"
                selected={@detail_key == "geofences"}
              />
              <.stat_card
                label="Attachments"
                value={@stats.attachments}
                icon="hero-paper-clip"
                color="teal"
                click_key="attachments"
                selected={@detail_key == "attachments"}
              />
              <.stat_card
                label="Activity Entries"
                value={@stats.activity_entries}
                icon="hero-list-bullet"
                color="violet"
                click_key="activity_entries"
                selected={@detail_key == "activity_entries"}
              />
            </div>
            <.detail_panel key={@detail_key} data={@detail_data} />
          </section>

          <%!-- VM Performance Section --%>
          <section>
            <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-500 mb-4">
              VM Performance
            </h2>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <.stat_card
                label="Total Memory"
                value={"#{@stats.vm.memory_total_mb} MB"}
                icon="hero-server"
                color="slate"
              />
              <.stat_card
                label="Process Memory"
                value={"#{@stats.vm.memory_processes_mb} MB"}
                icon="hero-cpu-chip"
                color="slate"
              />
            </div>
          </section>

          <%!-- Trends Section --%>
          <section>
            <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-500 mb-4">
              Trends — Last 30 Days
            </h2>
            <div class="grid md:grid-cols-2 gap-6">
              <.trend_table title="New User Registrations" rows={@user_trends} />
              <.trend_table title="New Events Created" rows={@event_trends} />
            </div>
          </section>

          <%!-- Error Panel --%>
          <section>
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-sm font-semibold uppercase tracking-wider text-gray-500">
                Error Log
                <span class="ml-2 text-xs font-normal text-gray-600">(last 200 entries)</span>
              </h2>
              <button
                :if={@error_groups != []}
                phx-click="clear_errors"
                class="text-xs text-red-400 hover:text-red-300 transition-colors"
              >
                Clear all
              </button>
            </div>

            <%= if @error_groups == [] do %>
              <div class="rounded-xl border border-dashed border-gray-800 p-8 text-center">
                <.icon name="hero-check-circle" class="w-8 h-8 text-emerald-500/60 mx-auto mb-2" />
                <p class="text-sm text-gray-500">No errors captured yet</p>
              </div>
            <% else %>
              <div class="rounded-xl border border-gray-800 overflow-hidden divide-y divide-gray-800">
                <%= for group <- @error_groups do %>
                  <.error_group_row
                    group={group}
                    expanded={MapSet.member?(@expanded_error_keys, group.key)}
                  />
                <% end %>
              </div>
            <% end %>
          </section>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ForceDark">
        export default {
          mounted() {
            this._prev = localStorage.getItem("phx:theme");
            localStorage.setItem("phx:theme", "dark");
            document.documentElement.setAttribute("data-theme", "dark");
          },
          destroyed() {
            if (this._prev === null) {
              localStorage.removeItem("phx:theme");
              document.documentElement.removeAttribute("data-theme");
            } else {
              localStorage.setItem("phx:theme", this._prev);
              document.documentElement.setAttribute("data-theme", this._prev);
            }
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # --- Private components ---

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :subtitle, :string, default: nil
  attr :click_key, :string, default: nil
  attr :selected, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div
      class={[
        "rounded-xl border p-5 transition-all duration-200",
        card_color_classes(@color),
        @click_key && "cursor-pointer select-none",
        @selected && "ring-1 ring-white/20"
      ]}
      phx-click={@click_key && "toggle_detail"}
      phx-value-key={@click_key}
    >
      <div class="flex items-start justify-between mb-3">
        <div class={["w-9 h-9 rounded-lg flex items-center justify-center", icon_bg_classes(@color)]}>
          <.icon name={@icon} class={["w-4.5 h-4.5", icon_color_classes(@color)]} />
        </div>
        <.icon
          :if={@click_key}
          name="hero-chevron-down"
          class={[
            "w-3.5 h-3.5 text-gray-600 transition-transform duration-200",
            @selected && "rotate-180"
          ]}
        />
      </div>
      <div class="text-2xl font-bold text-white tabular-nums">{@value}</div>
      <div class="text-sm text-gray-400 mt-0.5">{@label}</div>
      <div :if={@subtitle} class="text-xs text-gray-600 mt-0.5">{@subtitle}</div>
    </div>
    """
  end

  attr :key, :string, default: nil
  attr :data, :list, required: true

  defp detail_panel(assigns) do
    ~H"""
    <div
      :if={@key != nil}
      id="platform-detail-panel"
      class="mt-4 rounded-xl border border-gray-700/50 overflow-hidden"
    >
      <div class="px-4 py-3 bg-gray-900/60 border-b border-gray-800 flex items-center justify-between">
        <h3 class="text-sm font-medium text-gray-200">{detail_panel_title(@key)}</h3>
        <span class="text-xs text-gray-500">
          {length(@data)}{if length(@data) >= 100, do: " (first 100)", else: " records"}
        </span>
      </div>
      <%= if @data == [] do %>
        <div class="p-6 text-center text-sm text-gray-600">No records found</div>
      <% else %>
        <div class="overflow-auto max-h-72">
          <.detail_rows_table key={@key} data={@data} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :data, :list, required: true

  defp detail_rows_table(assigns) do
    ~H"""
    <table class="w-full text-sm">
      <%= cond do %>
        <% @key in ["users", "registered"] -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Email
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Display Name
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Type
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Role
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-300 text-xs font-mono">{row.email}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.display_name || "—"}</td>
                <td class="px-4 py-2 text-xs">
                  <span class={[
                    "inline-flex text-xs rounded px-1.5 py-0.5 border",
                    if(row.is_guest,
                      do: "bg-amber-500/10 text-amber-400 border-amber-500/20",
                      else: "bg-green-500/10 text-green-400 border-green-500/20"
                    )
                  ]}>
                    {if row.is_guest, do: "guest", else: "registered"}
                  </span>
                </td>
                <td class="px-4 py-2 text-xs">
                  <%= if row.superuser do %>
                    <span class="inline-flex text-xs rounded px-1.5 py-0.5 border bg-red-500/10 text-red-400 border-red-500/20 font-semibold">
                      superuser
                    </span>
                  <% else %>
                    <span class="text-gray-600">—</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "events" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Starts
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Ends
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Created
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-200 text-xs font-medium">{row.name}</td>
                <td class="px-4 py-2 text-gray-400 text-xs font-mono">
                  {format_short_dt(row.starts_at)}
                </td>
                <td class="px-4 py-2 text-gray-400 text-xs font-mono">
                  {format_short_dt(row.ends_at)}
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs font-mono">
                  {format_short_dt(row.inserted_at)}
                </td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "memberships" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Event
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                User
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Role
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Joined
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-200 text-xs font-medium">{row.event_name}</td>
                <td class="px-4 py-2 text-gray-400 text-xs font-mono">{row.user_email || "—"}</td>
                <td class="px-4 py-2 text-xs">
                  <span class="inline-flex text-xs rounded px-1.5 py-0.5 border bg-indigo-500/10 text-indigo-400 border-indigo-500/20">
                    {row.role}
                  </span>
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs font-mono">
                  {format_short_dt(row.joined_at)}
                </td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "pois" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Category
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Visibility
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-200 text-xs font-medium">{row.name}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.category}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.visibility}</td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "geofences" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Purpose
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Visibility
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-200 text-xs font-medium">{row.name}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.purpose}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.visibility}</td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "attachments" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Filename
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Content Type
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Created
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-gray-200 text-xs font-mono">{row.filename}</td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.content_type}</td>
                <td class="px-4 py-2 text-gray-500 text-xs font-mono">
                  {format_short_dt(row.inserted_at)}
                </td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "activity_entries" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Action
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Subject
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Message
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                When
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-xs">
                  <span class="inline-flex text-xs rounded px-1.5 py-0.5 border bg-violet-500/10 text-violet-400 border-violet-500/20">
                    {row.action}
                  </span>
                </td>
                <td class="px-4 py-2 text-gray-400 text-xs">{row.subject_type}</td>
                <td class="px-4 py-2 text-gray-400 text-xs truncate max-w-xs">
                  {String.slice(to_string(row.message), 0, 80)}
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs font-mono">
                  {format_short_dt(row.inserted_at)}
                </td>
              </tr>
            <% end %>
          </tbody>
        <% @key == "retention_runs" -> %>
          <thead>
            <tr class="border-b border-gray-800 bg-gray-900/40">
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Started
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Outcomes
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Failure
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= for row <- @data do %>
              <tr class="hover:bg-gray-800/30 transition-colors">
                <td class="px-4 py-2 text-xs">
                  <span class={[
                    "inline-flex text-xs rounded px-1.5 py-0.5 border",
                    if(row.status == "completed",
                      do: "bg-emerald-500/10 text-emerald-400 border-emerald-500/20",
                      else: "bg-red-500/10 text-red-400 border-red-500/20"
                    )
                  ]}>
                    {row.status}
                  </span>
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs font-mono">
                  {format_short_dt(row.started_at)}
                </td>
                <td class="px-4 py-2 text-gray-400 text-xs font-mono">
                  {format_counts(row.outcome_counts)}
                </td>
                <td class="px-4 py-2 text-gray-400 text-xs">
                  {row.failure_reason || "—"}
                </td>
              </tr>
            <% end %>
          </tbody>
        <% true -> %>
      <% end %>
    </table>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp trend_table(assigns) do
    ~H"""
    <div class="rounded-xl border border-gray-800 overflow-hidden">
      <div class="px-4 py-3 bg-gray-900/50 border-b border-gray-800">
        <h3 class="text-sm font-medium text-gray-300">{@title}</h3>
      </div>
      <%= if @rows == [] do %>
        <div class="p-4 text-center text-sm text-gray-600">No data for the last 30 days</div>
      <% else %>
        <div class="overflow-y-auto max-h-48">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-gray-800">
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Date
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Count
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800/50">
              <%= for row <- @rows do %>
                <tr class="hover:bg-gray-800/30 transition-colors">
                  <td class="px-4 py-2 text-gray-300 font-mono text-xs">
                    {to_string(row.date)}
                  </td>
                  <td class="px-4 py-2 text-right text-white font-semibold tabular-nums">
                    {row.count}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :expanded, :boolean, required: true

  defp error_group_row(assigns) do
    ~H"""
    <div class="bg-gray-900/30">
      <button
        phx-click="toggle_error_group"
        phx-value-key={@group.key}
        class="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-gray-800/40 transition-colors"
      >
        <div class="flex-shrink-0 w-2 h-2 rounded-full bg-red-500/80"></div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <span class="text-xs font-mono text-red-400/80">{@group.module}</span>
            <span class="text-gray-600 text-xs">·</span>
            <span class="text-xs text-gray-400 truncate">{@group.message_prefix}</span>
          </div>
          <div class="text-xs text-gray-600 mt-0.5">
            {format_timestamp(@group.last_seen)}
          </div>
        </div>
        <div class="flex items-center gap-2 flex-shrink-0">
          <span class="text-xs font-semibold text-red-400 bg-red-500/10 border border-red-500/20 rounded-full px-2 py-0.5">
            ×{@group.count}
          </span>
          <.icon
            name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="w-4 h-4 text-gray-600"
          />
        </div>
      </button>
      <div
        :if={@expanded}
        class="px-4 pb-3 ml-6 border-l border-gray-800 ml-10"
      >
        <pre class="text-xs text-gray-400 bg-gray-950/60 rounded-lg p-3 overflow-x-auto whitespace-pre-wrap break-words font-mono"><%= @group.sample %></pre>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  @spec load_all_stats(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_all_stats(socket) do
    stats = Stats.dashboard_stats()
    user_trends = Stats.user_trend_30_days()
    event_trends = Stats.event_trend_30_days()
    error_groups = ErrorBuffer.grouped_errors()

    socket
    |> assign(:stats, stats)
    |> assign(:user_trends, user_trends)
    |> assign(:event_trends, event_trends)
    |> assign(:error_groups, error_groups)
    |> assign(:last_updated, DateTime.utc_now())
    |> assign_new(:expanded_error_keys, fn -> MapSet.new() end)
    |> assign_new(:detail_key, fn -> nil end)
    |> refresh_detail_panel()
  end

  @spec refresh_detail_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_detail_panel(socket) do
    case socket.assigns.detail_key do
      nil -> assign_new(socket, :detail_data, fn -> [] end)
      key -> assign(socket, :detail_data, Stats.detail_rows(key))
    end
  end

  @spec schedule_refresh() :: reference()
  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  @spec format_timestamp(DateTime.t()) :: String.t()
  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  @spec detail_panel_title(String.t()) :: String.t()
  defp detail_panel_title("users"), do: "All Users"
  defp detail_panel_title("registered"), do: "Registered Users"
  defp detail_panel_title("events"), do: "All Events"
  defp detail_panel_title("memberships"), do: "All Memberships"
  defp detail_panel_title("pois"), do: "All Points of Interest"
  defp detail_panel_title("geofences"), do: "All Geofences"
  defp detail_panel_title("attachments"), do: "All Attachments"
  defp detail_panel_title("activity_entries"), do: "Activity Log Entries"
  defp detail_panel_title("retention_runs"), do: "Retention Cleanup Runs"
  defp detail_panel_title(_), do: "Detail View"

  @spec retention_subtitle(map()) :: String.t()
  defp retention_subtitle(%{last_status: nil}), do: "not run yet"

  defp retention_subtitle(%{last_status: status, recent_failures: failures}) when failures > 0 do
    "#{status} · #{failures} failures"
  end

  defp retention_subtitle(%{last_status: status}), do: to_string(status)

  @spec format_counts(map() | nil) :: String.t()
  defp format_counts(nil), do: "—"

  defp format_counts(counts) do
    counts
    |> Enum.reject(fn {_key, value} -> value in [nil, 0] end)
    |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
    |> Enum.join(", ")
    |> case do
      "" -> "no changes"
      text -> text
    end
  end

  @spec format_short_dt(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  defp format_short_dt(nil), do: "—"
  defp format_short_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_short_dt(%NaiveDateTime{} = dt),
    do: NaiveDateTime.to_string(dt) |> String.slice(0, 16)

  @spec card_color_classes(String.t()) :: String.t()
  defp card_color_classes("blue"), do: "border-blue-500/20 bg-blue-500/5 hover:bg-blue-500/10"
  defp card_color_classes("green"), do: "border-green-500/20 bg-green-500/5 hover:bg-green-500/10"

  defp card_color_classes("purple"),
    do: "border-purple-500/20 bg-purple-500/5 hover:bg-purple-500/10"

  defp card_color_classes("cyan"), do: "border-cyan-500/20 bg-cyan-500/5 hover:bg-cyan-500/10"
  defp card_color_classes("rose"), do: "border-rose-500/20 bg-rose-500/5 hover:bg-rose-500/10"

  defp card_color_classes("orange"),
    do: "border-orange-500/20 bg-orange-500/5 hover:bg-orange-500/10"

  defp card_color_classes("teal"), do: "border-teal-500/20 bg-teal-500/5 hover:bg-teal-500/10"

  defp card_color_classes("violet"),
    do: "border-violet-500/20 bg-violet-500/5 hover:bg-violet-500/10"

  defp card_color_classes("indigo"),
    do: "border-indigo-500/20 bg-indigo-500/5 hover:bg-indigo-500/10"

  defp card_color_classes("amber"), do: "border-amber-500/20 bg-amber-500/5 hover:bg-amber-500/10"

  defp card_color_classes("emerald"),
    do: "border-emerald-500/20 bg-emerald-500/5 hover:bg-emerald-500/10"

  defp card_color_classes("slate"), do: "border-slate-500/20 bg-slate-500/5 hover:bg-slate-500/10"
  defp card_color_classes(_), do: "border-gray-800 bg-gray-900/50"

  @spec icon_bg_classes(String.t()) :: String.t()
  defp icon_bg_classes("blue"), do: "bg-blue-500/10"
  defp icon_bg_classes("green"), do: "bg-green-500/10"
  defp icon_bg_classes("purple"), do: "bg-purple-500/10"
  defp icon_bg_classes("cyan"), do: "bg-cyan-500/10"
  defp icon_bg_classes("rose"), do: "bg-rose-500/10"
  defp icon_bg_classes("orange"), do: "bg-orange-500/10"
  defp icon_bg_classes("teal"), do: "bg-teal-500/10"
  defp icon_bg_classes("violet"), do: "bg-violet-500/10"
  defp icon_bg_classes("indigo"), do: "bg-indigo-500/10"
  defp icon_bg_classes("amber"), do: "bg-amber-500/10"
  defp icon_bg_classes("emerald"), do: "bg-emerald-500/10"
  defp icon_bg_classes("slate"), do: "bg-slate-500/10"
  defp icon_bg_classes(_), do: "bg-gray-800"

  @spec icon_color_classes(String.t()) :: String.t()
  defp icon_color_classes("blue"), do: "text-blue-400"
  defp icon_color_classes("green"), do: "text-green-400"
  defp icon_color_classes("purple"), do: "text-purple-400"
  defp icon_color_classes("cyan"), do: "text-cyan-400"
  defp icon_color_classes("rose"), do: "text-rose-400"
  defp icon_color_classes("orange"), do: "text-orange-400"
  defp icon_color_classes("teal"), do: "text-teal-400"
  defp icon_color_classes("violet"), do: "text-violet-400"
  defp icon_color_classes("indigo"), do: "text-indigo-400"
  defp icon_color_classes("amber"), do: "text-amber-400"
  defp icon_color_classes("emerald"), do: "text-emerald-400"
  defp icon_color_classes("slate"), do: "text-slate-400"
  defp icon_color_classes(_), do: "text-gray-400"
end
