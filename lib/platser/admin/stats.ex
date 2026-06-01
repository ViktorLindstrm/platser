defmodule Platser.Admin.Stats do
  @moduledoc """
  Aggregated statistics for the admin dashboard.

  All queries run with `authorize?: false` and are intended to be called
  only from admin-protected LiveViews.
  """

  import Ecto.Query

  require Ash.Query

  alias Platser.Repo

  @type count_stats :: %{
          users: non_neg_integer(),
          guests: non_neg_integer(),
          registered: non_neg_integer(),
          events: non_neg_integer(),
          memberships: non_neg_integer(),
          pois: non_neg_integer(),
          geofences: non_neg_integer(),
          attachments: non_neg_integer(),
          activity_entries: non_neg_integer()
        }

  @type day_trend :: %{date: Date.t(), count: non_neg_integer()}

  @type vm_stats :: %{
          memory_total_mb: non_neg_integer(),
          memory_processes_mb: non_neg_integer(),
          process_count: non_neg_integer(),
          run_queue: non_neg_integer()
        }

  @doc "Returns total counts for all major resources."
  @spec total_counts() :: count_stats()
  def total_counts do
    users_total = Platser.Accounts.User |> Ash.count!(authorize?: false)

    guests =
      Platser.Accounts.User
      |> Ash.Query.filter(is_guest == true)
      |> Ash.count!(authorize?: false)

    events = Platser.Events.Event |> Ash.count!(authorize?: false)
    memberships = Platser.Events.Membership |> Ash.count!(authorize?: false)
    pois = Platser.Map.Poi |> Ash.count!(authorize?: false)
    geofences = Platser.Map.Geofence |> Ash.count!(authorize?: false)
    attachments = Platser.Media.Attachment |> Ash.count!(authorize?: false)
    activity_entries = Platser.Activity.Entry |> Ash.count!(authorize?: false)

    %{
      users: users_total,
      guests: guests,
      registered: users_total - guests,
      events: events,
      memberships: memberships,
      pois: pois,
      geofences: geofences,
      attachments: attachments,
      activity_entries: activity_entries
    }
  end

  @doc "Returns the number of activity entries created in the last 60 minutes."
  @spec recent_activity_count() :: non_neg_integer()
  def recent_activity_count do
    sixty_min_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.aggregate(
      from(e in "entries", where: e.inserted_at >= ^sixty_min_ago),
      :count,
      :id
    )
  end

  @doc "Returns new user registrations grouped by day for the last 30 days."
  @spec user_trend_30_days() :: [day_trend()]
  def user_trend_30_days do
    thirty_days_ago = Date.add(Date.utc_today(), -30)

    Repo.all(
      from u in "users",
        where: fragment("DATE(? AT TIME ZONE 'UTC')", u.inserted_at) >= ^thirty_days_ago,
        group_by: fragment("DATE(? AT TIME ZONE 'UTC')", u.inserted_at),
        select: %{
          date: fragment("DATE(? AT TIME ZONE 'UTC')", u.inserted_at),
          count: count(u.id)
        },
        order_by: [asc: fragment("DATE(? AT TIME ZONE 'UTC')", u.inserted_at)]
    )
  end

  @doc "Returns new events created grouped by day for the last 30 days."
  @spec event_trend_30_days() :: [day_trend()]
  def event_trend_30_days do
    thirty_days_ago = Date.add(Date.utc_today(), -30)

    Repo.all(
      from e in "events",
        where: fragment("DATE(? AT TIME ZONE 'UTC')", e.inserted_at) >= ^thirty_days_ago,
        group_by: fragment("DATE(? AT TIME ZONE 'UTC')", e.inserted_at),
        select: %{
          date: fragment("DATE(? AT TIME ZONE 'UTC')", e.inserted_at),
          count: count(e.id)
        },
        order_by: [asc: fragment("DATE(? AT TIME ZONE 'UTC')", e.inserted_at)]
    )
  end

  @doc "Returns current BEAM VM statistics."
  @spec vm_stats() :: vm_stats()
  def vm_stats do
    mem = :erlang.memory()
    process_count = :erlang.system_info(:process_count)
    run_queue = :erlang.statistics(:run_queue)

    %{
      memory_total_mb: div(mem[:total], 1_048_576),
      memory_processes_mb: div(mem[:processes], 1_048_576),
      process_count: process_count,
      run_queue: run_queue
    }
  end

  @doc """
  Returns a combined stats map for dashboard rendering.
  Groups total_counts + recent_activity + vm_stats into one map.
  """
  @spec dashboard_stats() :: map()
  def dashboard_stats do
    counts = total_counts()

    Map.merge(counts, %{
      recent_activity: recent_activity_count(),
      vm: vm_stats()
    })
  end
end
