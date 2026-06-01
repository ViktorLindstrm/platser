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
      <div class="min-h-[calc(100vh-3.5rem)] bg-gray-950 text-gray-100">
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
            <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
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
              />
              <.stat_card
                label="Registered"
                value={@stats.registered}
                icon="hero-user-check"
                color="green"
              />
              <.stat_card
                label="Events"
                value={@stats.events}
                icon="hero-calendar"
                color="purple"
              />
              <.stat_card
                label="Memberships"
                value={@stats.memberships}
                icon="hero-user-group"
                color="cyan"
              />
              <.stat_card
                label="POIs"
                value={@stats.pois}
                icon="hero-map-pin"
                color="rose"
              />
              <.stat_card
                label="Geofences"
                value={@stats.geofences}
                icon="hero-map"
                color="orange"
              />
              <.stat_card
                label="Attachments"
                value={@stats.attachments}
                icon="hero-paper-clip"
                color="teal"
              />
              <.stat_card
                label="Activity Entries"
                value={@stats.activity_entries}
                icon="hero-list-bullet"
                color="violet"
              />
            </div>
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
    </Layouts.app>
    """
  end

  # --- Private components ---

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :subtitle, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border p-5 transition-all duration-200",
      card_color_classes(@color)
    ]}>
      <div class="flex items-start justify-between mb-3">
        <div class={["w-9 h-9 rounded-lg flex items-center justify-center", icon_bg_classes(@color)]}>
          <.icon name={@icon} class={["w-4.5 h-4.5", icon_color_classes(@color)]} />
        </div>
      </div>
      <div class="text-2xl font-bold text-white tabular-nums">{@value}</div>
      <div class="text-sm text-gray-400 mt-0.5">{@label}</div>
      <div :if={@subtitle} class="text-xs text-gray-600 mt-0.5">{@subtitle}</div>
    </div>
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
  end

  @spec schedule_refresh() :: reference()
  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  @spec format_timestamp(DateTime.t()) :: String.t()
  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

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
