# ADR-0030 — Administrator Dashboard

**Status:** Accepted  
**Date:** 2026-06-01  
**Authors:** Copilot  
**Relates to:** ADR-0004 (Domain Model), ADR-0012 (Authentication), ADR-0026 (Guest Users)

---

## Context

The platform has grown beyond a handful of test users and events.  
Operators need a single view for:

- **Usage statistics** — how many users, events, memberships, POIs, etc. exist.
- **Growth trends** — registrations and event creation over the last 30 days.
- **Error log** — recent error/critical/alert log entries without tailing a file.
- **VM metrics** — process count, run queue, and memory at a glance.

A lightweight, purpose-built LiveView dashboard was chosen over installing Phoenix LiveDashboard as the *sole* operations interface, because it can surface domain-specific counters (guest users, geofences, memberships) alongside VM data in one cohesive screen.  
Phoenix LiveDashboard is still mounted separately for deep BEAM introspection.

---

## Decision

### 1. Superuser access control

A `superuser` boolean attribute is added to `Platser.Accounts.User` (default `false`, non-public, not writable through standard actions).  
A dedicated `set_superuser` update action is protected by `forbid_if always()` — the policy unconditionally forbids it so it can only be invoked with `authorize?: false` in trusted internal code (seeds, IEx console).

The pattern ensures superuser promotion cannot happen through any normal user request path, even if the client bypasses UI checks.

**Why a boolean flag rather than a role resource?**  
The platform currently has only one privileged role at the operator level.  
A join-table roles system adds indirection without value at this scale.  
Should multiple admin roles be needed later, the `superuser` flag can be migrated to a set-valued attribute or a separate `roles` resource.

### 2. LiveView route guard

`PlatserWeb.LiveUserAuth.on_mount(:ensure_superuser, ...)` is a new on_mount guard that reads `current_user.superuser`.  
Non-superusers (including unauthenticated visitors) are redirected to `/` with a flash message.

The `:admin` live_session chains three on_mount hooks in order:

1. `AshAuthentication.Phoenix.LiveSession` — populates `current_user`
2. `PlatserWeb.LiveUserAuth` (`:live_user_required`) — rejects unauthenticated requests
3. `PlatserWeb.LiveUserAuth` (`:ensure_superuser`) — rejects non-superusers

This layered approach reuses existing authentication infrastructure (ADR-0012) rather than duplicating session handling.

### 3. Error buffer

`Platser.Admin.ErrorBuffer` is a hand-rolled GenServer with an ETS `ordered_set` backing store.  
It registers itself as an OTP `:logger` handler and writes entries directly to ETS in the `log/2` callback (bypassing the GenServer mailbox) to avoid blocking high-frequency logging.

Entries are keyed by `:erlang.unique_integer([:monotonic, :positive])` to preserve arrival order.  
The buffer is capped at 200 entries; the oldest entry is evicted when the limit is reached.

**Why hand-rolled over a library like `error_tracker`?**  
The requirement is an in-memory ring buffer for *operator awareness*, not a persistent exception tracker.  
A GenServer + ETS is ~100 lines of straightforward Elixir, has zero extra dependencies, and avoids the operational complexity of a persistent error database for what is essentially a dashboard widget.  
If the project later needs persistent error tracking with stack traces and grouping, adopting `error_tracker` at that point is straightforward.

### 4. Stats module

`Platser.Admin.Stats` is a plain module (not a GenServer) that computes statistics on demand.  
It mixes two data sources:

- **Ash 3.0 counts** — `Ash.count!(Resource, authorize?: false)` for total records per domain resource. This respects Ash's query pipeline and stays consistent with domain definitions.
- **Raw Ecto queries** — for trend analysis (GROUP BY date), because Ash's expression language does not natively support the `DATE(... AT TIME ZONE 'UTC')` aggregation used here.

Raw Ecto is explicitly scoped to read-only aggregate queries; no writes or mutations use raw Ecto.

### 5. Events table timestamps

The `events` table initially had no `inserted_at` column.  
A `create_timestamp :inserted_at` attribute was added to `Platser.Events.Event` and a migration generated to backfill the column (NULL for existing rows).  
`starts_at` was not used as a proxy because it represents the event's scheduled start, not its creation time.

### 6. LiveDashboard route isolation

Phoenix LiveDashboard registers an internal `live_session` named `:live_dashboard`.  
To avoid a name conflict when both the dev dashboard and the admin dashboard are present in the same router, the router uses a compile-time `if` on `:dev_routes`:

- **Dev** — LiveDashboard at `/dev/dashboard` (no auth required)
- **Production** — LiveDashboard at `/admin/live_dashboard` (protected by `require_superuser` Plug)

---

## Consequences

**Positive**
- Operators have a fast, self-refreshing (30 s) view of platform health in one screen.
- The `superuser` flag is impossible to set through the normal auth path, minimising privilege-escalation risk.
- Zero new runtime dependencies.
- The error buffer is self-cleaning; it never consumes unbounded memory.

**Negative / trade-offs**
- The error buffer is volatile — a node restart loses all buffered entries.
- Trend queries are raw Ecto SQL; they do not benefit from Ash's policy layer (they are run inside the already-guarded admin LiveView).
- The `inserted_at` column for events is NULL for all events created before the migration ran.

**Follow-up work if needed**
- If multiple admin roles are required, promote `superuser` to a `roles` attribute.
- If persistent error tracking is required, adopt `error_tracker` and remove `ErrorBuffer`.
- If trend queries become slow, add a `BRIN` index on `events.inserted_at`.
