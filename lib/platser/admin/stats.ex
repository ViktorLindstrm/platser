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
          activity_entries: non_neg_integer(),
          retention_runs: non_neg_integer()
        }

  @type day_trend :: %{date: Date.t(), count: non_neg_integer()}

  @type retention_summary :: %{
          last_status: atom() | nil,
          last_started_at: DateTime.t() | nil,
          last_completed_at: DateTime.t() | nil,
          recent_failures: non_neg_integer()
        }

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
    retention_runs = Platser.Privacy.RetentionRun |> Ash.count!(authorize?: false)

    %{
      users: users_total,
      guests: guests,
      registered: users_total - guests,
      events: events,
      memberships: memberships,
      pois: pois,
      geofences: geofences,
      attachments: attachments,
      activity_entries: activity_entries,
      retention_runs: retention_runs
    }
  end

  @doc "Returns aggregate retention cleanup status for the admin dashboard."
  @spec retention_summary() :: retention_summary()
  def retention_summary do
    last =
      Repo.one(
        from r in "privacy_retention_runs",
          select: %{
            status: r.status,
            started_at: r.started_at,
            completed_at: r.completed_at
          },
          order_by: [desc: r.started_at],
          limit: 1
      )

    day_ago = DateTime.add(DateTime.utc_now(:second), -1, :day)

    recent_failures =
      Repo.aggregate(
        from(r in "privacy_retention_runs",
          where: r.status == "failed" and r.started_at >= ^day_ago
        ),
        :count,
        :id
      )

    %{
      last_status: status_atom(last && last.status),
      last_started_at: last && last.started_at,
      last_completed_at: last && last.completed_at,
      recent_failures: recent_failures
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

  @doc "Returns up to 100 detail records for the given platform total key."
  @spec detail_rows(String.t()) :: [map()]
  def detail_rows("users") do
    Repo.all(
      from u in "users",
        select: %{
          email: u.email,
          display_name: u.display_name,
          is_guest: u.is_guest,
          superuser: u.superuser
        },
        order_by: [asc: u.email],
        limit: 100
    )
  end

  def detail_rows("registered") do
    Repo.all(
      from u in "users",
        where: u.is_guest == false,
        select: %{
          email: u.email,
          display_name: u.display_name,
          is_guest: u.is_guest,
          superuser: u.superuser
        },
        order_by: [asc: u.email],
        limit: 100
    )
  end

  def detail_rows("events") do
    Repo.all(
      from e in "events",
        select: %{
          name: e.name,
          starts_at: e.starts_at,
          ends_at: e.ends_at,
          inserted_at: e.inserted_at
        },
        order_by: [desc: e.inserted_at],
        limit: 100
    )
  end

  def detail_rows("memberships") do
    Repo.all(
      from m in "memberships",
        join: e in "events",
        on: e.id == m.event_id,
        left_join: u in "users",
        on: u.id == m.user_id,
        select: %{role: m.role, joined_at: m.joined_at, event_name: e.name, user_email: u.email},
        order_by: [desc: m.joined_at],
        limit: 100
    )
  end

  def detail_rows("pois") do
    Repo.all(
      from p in "pois",
        select: %{name: p.name, category: p.category, visibility: p.visibility},
        order_by: [asc: p.name],
        limit: 100
    )
  end

  def detail_rows("geofences") do
    Repo.all(
      from g in "geofences",
        select: %{name: g.name, purpose: g.purpose, visibility: g.visibility},
        order_by: [asc: g.name],
        limit: 100
    )
  end

  def detail_rows("attachments") do
    Repo.all(
      from a in "media_attachments",
        select: %{filename: a.filename, content_type: a.content_type, inserted_at: a.inserted_at},
        order_by: [desc: a.inserted_at],
        limit: 100
    )
  end

  def detail_rows("activity_entries") do
    Repo.all(
      from e in "entries",
        select: %{
          action: e.action,
          subject_type: e.subject_type,
          message: e.message,
          inserted_at: e.inserted_at
        },
        order_by: [desc: e.inserted_at],
        limit: 100
    )
  end

  def detail_rows("retention_runs") do
    Repo.all(
      from r in "privacy_retention_runs",
        select: %{
          status: r.status,
          started_at: r.started_at,
          completed_at: r.completed_at,
          outcome_counts: r.outcome_counts,
          failure_reason: r.failure_reason
        },
        order_by: [desc: r.started_at],
        limit: 100
    )
  end

  def detail_rows(_), do: []

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
      retention: retention_summary(),
      vm: vm_stats()
    })
  end

  @spec status_atom(String.t() | nil) :: atom() | nil
  defp status_atom(nil), do: nil
  defp status_atom("completed"), do: :completed
  defp status_atom("failed"), do: :failed
  defp status_atom(_), do: nil
end
