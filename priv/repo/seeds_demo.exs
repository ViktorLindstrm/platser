# priv/repo/seeds_demo.exs
#
# Demo seed script — Humlegården Festival Grounds
# =================================================
# Populates a self-contained demo event with realistic POIs, geofences,
# and simulator route waypoints set in Humlegården, Stockholm.
#
# Run with:
#   mix run priv/repo/seeds_demo.exs
#
# This script is idempotent: re-running it will reuse the existing demo event
# and demo users, but will wipe and recreate all POIs and geofences.
#
# Layout
# ------
#   Event:    "Humlegården Demo"   join_code: DEMO01
#   Bounds:   59.3395°N–59.3460°N, 18.069°E–18.081°E
#
#   Geofences (all published):
#     1. [boundary]     Park Perimeter        — green  — whole area
#     2. [meeting_zone] Central Gathering     — blue   — centre lawn
#     3. [restricted]   Stage Area            — red    — east production zone
#     4. [camp_area]    Base Camp             — orange — west camp zone
#
#   POIs (mix of published / draft):
#      1. [viewpoint]     Kungsplan Lookout   — published — description + comment
#      2. [camp]          Base Camp Alpha     — published — description only
#      3. [meeting_point] Central Meetup      — published — description + comment
#      4. [food]          Fika Station        — published — description + comment
#      5. [hazard]        Slippery Path       — published — description only
#      6. [other]         Info Board          — published — comment only (no desc)
#      7. [meeting_point] Backup Meetup       — draft     — description only
#      8. [viewpoint]     East Overlook       — draft     — no description/comment
#      9. [food]          Water Point         — published — description only
#     10. [camp]          Emergency Shelter   — published — description only
#
#   Demo users (is_simulated: true — picked up by GPS simulator):
#     demo-admin@dev.local  (Demo Admin)   — event admin
#     demo-alice@dev.local  (Alice Demo)   — event member
#     demo-bob@dev.local    (Bob Demo)     — event member
#
#   Simulator routes (lat, lng tuples for the :route pattern):
#     perimeter_patrol — alice walks the outer boundary
#     food_run         — bob visits food / meeting POIs
#     camp_check       — admin patrols between camp areas
#
# GPS Simulator setup (manual — via dev simulator panel or IEx):
# ---------------------------------------------------------------
#   1. Open the Dev Simulator panel in the app.
#   2. Note the Demo Event ID printed at the end of this script.
#   3. Set the simulator event to that ID:
#        Platser.Dev.GpsSimulator.set_event("<demo_event_id>")
#   4. Copy the route waypoints printed below and add demo users:
#        Platser.Dev.GpsSimulator.add_user(alice, :route, points: perimeter_patrol)
#        Platser.Dev.GpsSimulator.add_user(bob,   :route, points: food_run)

require Ash.Query

# ── Simulator route waypoints ─────────────────────────────────────────────────

perimeter_patrol = [
  {59.3456, 18.0698},
  {59.3456, 18.0740},
  {59.3456, 18.0800},
  {59.3418, 18.0800},
  {59.3398, 18.0800},
  {59.3398, 18.0720},
  {59.3398, 18.0698},
  {59.3430, 18.0698}
]

food_run = [
  {59.3430, 18.0741},
  {59.3421, 18.0761},
  {59.3411, 18.0756},
  {59.3420, 18.0740},
  {59.3430, 18.0741}
]

camp_check = [
  {59.3428, 18.0709},
  {59.3444, 18.0720},
  {59.3451, 18.0703},
  {59.3435, 18.0700},
  {59.3428, 18.0709}
]

# ── Helpers ───────────────────────────────────────────────────────────────────

find_or_create_sim_user = fn email, display_name ->
  case Platser.Accounts.User
       |> Ash.Query.filter(email == ^email)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      Platser.Accounts.User
      |> Ash.Changeset.for_create(:create_simulated, %{
        email: email,
        display_name: display_name
      })
      |> Ash.create!(authorize?: false)

    {:ok, existing} ->
      existing
  end
end

polygon = fn coords ->
  %Geo.Polygon{coordinates: [coords], srid: 4326}
end

point = fn lng, lat ->
  %Geo.Point{coordinates: {lng, lat}, srid: 4326}
end

# ── Demo users ────────────────────────────────────────────────────────────────

IO.puts("Setting up demo users...")

demo_admin = find_or_create_sim_user.("demo-admin@dev.local", "Demo Admin")
demo_alice = find_or_create_sim_user.("demo-alice@dev.local", "Alice Demo")
demo_bob = find_or_create_sim_user.("demo-bob@dev.local", "Bob Demo")

IO.puts("  admin: #{demo_admin.email}")
IO.puts("  alice: #{demo_alice.email}")
IO.puts("  bob:   #{demo_bob.email}")

# ── Demo event ────────────────────────────────────────────────────────────────

IO.puts("Setting up demo event...")

demo_join_code = "DEMO01"

event =
  case Platser.Events.Event
       |> Ash.Query.filter(join_code == ^demo_join_code)
       |> Ash.read_one(authorize?: false) do
    {:ok, %{} = existing} ->
      IO.puts("  Found existing demo event (#{existing.id})")
      existing

    {:ok, nil} ->
      IO.puts("  Creating demo event...")
      now = DateTime.utc_now()

      created =
        Platser.Events.Event
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Humlegården Demo",
            description:
              "Demo event set in Humlegården, Stockholm. Explore POIs, geofences, and live location sharing!",
            starts_at: now,
            ends_at: DateTime.add(now, 7 * 24 * 3600, :second)
          },
          actor: demo_admin
        )
        |> Ash.create!(authorize?: false)

      # Patch the join code to the well-known demo value via a direct Ecto update.
      # GenerateJoinCode always overwrites on create, so we fix it afterwards.
      Platser.Repo.update!(Ecto.Changeset.change(created, join_code: demo_join_code))
  end

# ── Set event bounds ──────────────────────────────────────────────────────────

event_bounds = polygon.([
  {18.0690, 59.3460},
  {18.0810, 59.3460},
  {18.0810, 59.3395},
  {18.0690, 59.3395},
  {18.0690, 59.3460}
])

event
|> Ash.Changeset.for_update(:set_bounds, %{bounds: event_bounds}, actor: demo_admin)
|> Ash.update!(authorize?: false)

IO.puts("  Bounds set.")

# ── Memberships ───────────────────────────────────────────────────────────────
#
# demo_admin already gets an admin membership from CreateAdminMembership in the
# Event :create action.  We use raw SQL for alice and bob so we can assign
# :member role without adding a new Ash action to the production codebase.

IO.puts("Setting up memberships...")

ensure_admin_membership = fn user ->
  case Platser.Events.Membership
       |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      Platser.Events.Membership
      |> Ash.Changeset.for_create(:create_admin, %{
        event_id: event.id,
        user_id: user.id
      })
      |> Ash.create!(authorize?: false)

      IO.puts("  Created admin membership for #{user.email}")

    {:ok, _} ->
      IO.puts("  Admin membership already exists for #{user.email}")
  end
end

ensure_member_membership = fn user ->
  case Platser.Events.Membership
       |> Ash.Query.filter(event_id == ^event.id and user_id == ^user.id)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      Platser.Repo.query!(
        """
        INSERT INTO memberships (id, event_id, user_id, role, joined_at)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(event.id),
          Ecto.UUID.dump!(user.id),
          "member",
          DateTime.utc_now()
        ]
      )

      IO.puts("  Created member membership for #{user.email}")

    {:ok, _} ->
      IO.puts("  Member membership already exists for #{user.email}")
  end
end

ensure_admin_membership.(demo_admin)
ensure_member_membership.(demo_alice)
ensure_member_membership.(demo_bob)

# ── Clear existing POIs and geofences (idempotent reseed) ─────────────────────
#
# Published items cannot be edited, so we wipe and recreate all map data.

IO.puts("Clearing existing demo POIs and geofences...")

existing_pois =
  Platser.Map.Poi
  |> Ash.Query.for_read(:list_by_event, %{event_id: event.id})
  |> Ash.read!(authorize?: false)

Enum.each(existing_pois, &Ash.destroy!(&1, authorize?: false))
IO.puts("  Deleted #{length(existing_pois)} POI(s)")

existing_geofences =
  Platser.Map.Geofence
  |> Ash.Query.for_read(:list_by_event, %{event_id: event.id})
  |> Ash.read!(authorize?: false)

Enum.each(existing_geofences, &Ash.destroy!(&1, authorize?: false))
IO.puts("  Deleted #{length(existing_geofences)} geofence(s)")

# ── Geofences ─────────────────────────────────────────────────────────────────

IO.puts("Creating geofences...")

create_and_publish_geofence = fn attrs ->
  geofence =
    Platser.Map.Geofence
    |> Ash.Changeset.for_create(:create, attrs, actor: demo_admin)
    |> Ash.create!(authorize?: false)

  geofence
  |> Ash.Changeset.for_update(:publish, %{}, actor: demo_admin)
  |> Ash.update!(authorize?: false)
end

# 1. Park Perimeter — boundary
create_and_publish_geofence.(%{
  name: "Park Perimeter",
  purpose: :boundary,
  color: "#22c55e",
  description: "Outer boundary of the Humlegården festival grounds.",
  event_id: event.id,
  geometry:
    polygon.([
      {18.0695, 59.3458},
      {18.0802, 59.3458},
      {18.0802, 59.3398},
      {18.0695, 59.3398},
      {18.0695, 59.3458}
    ])
})

# 2. Central Gathering — meeting_zone
create_and_publish_geofence.(%{
  name: "Central Gathering",
  purpose: :meeting_zone,
  color: "#3b82f6",
  description: "Main open lawn for group meetups and announcements.",
  event_id: event.id,
  geometry:
    polygon.([
      {18.0720, 59.3442},
      {18.0762, 59.3442},
      {18.0762, 59.3416},
      {18.0720, 59.3416},
      {18.0720, 59.3442}
    ])
})

# 3. Stage Area — restricted
create_and_publish_geofence.(%{
  name: "Stage Area",
  purpose: :restricted,
  color: "#ef4444",
  description: "Restricted backstage and production zone. Crew only.",
  event_id: event.id,
  geometry:
    polygon.([
      {18.0778, 59.3452},
      {18.0802, 59.3452},
      {18.0802, 59.3432},
      {18.0778, 59.3432},
      {18.0778, 59.3452}
    ])
})

# 4. Base Camp — camp_area
create_and_publish_geofence.(%{
  name: "Base Camp",
  purpose: :camp_area,
  color: "#f97316",
  event_id: event.id,
  geometry:
    polygon.([
      {18.0698, 59.3436},
      {18.0718, 59.3436},
      {18.0718, 59.3416},
      {18.0698, 59.3416},
      {18.0698, 59.3436}
    ])
})

IO.puts("  4 geofences created and published")

# ── POIs ──────────────────────────────────────────────────────────────────────

IO.puts("Creating POIs...")

create_poi = fn attrs, publish? ->
  {comment, create_attrs} = Map.pop(attrs, :comment)

  poi =
    Platser.Map.Poi
    |> Ash.Changeset.for_create(:create, create_attrs, actor: demo_admin)
    |> Ash.create!(authorize?: false)

  poi =
    if comment do
      poi
      |> Ash.Changeset.for_update(:update_comment, %{comment: comment}, actor: demo_admin)
      |> Ash.update!(authorize?: false)
    else
      poi
    end

  if publish? do
    poi
    |> Ash.Changeset.for_update(:publish, %{}, actor: demo_admin)
    |> Ash.update!(authorize?: false)
  else
    poi
  end
end

# 1. Viewpoint — published — description + comment
create_poi.(
  %{
    name: "Kungsplan Lookout",
    category: :viewpoint,
    description: "Elevated vantage point on the northern ridge. Great for crowd orientation.",
    comment: "Best angle at sunset — worth the climb!",
    location: point.(18.0749, 59.3447),
    event_id: event.id
  },
  true
)

# 2. Camp — published — description only
create_poi.(
  %{
    name: "Base Camp Alpha",
    category: :camp,
    description: "Primary camp setup near the western tree line. Tents and shared gear stored here.",
    location: point.(18.0709, 59.3428),
    event_id: event.id
  },
  true
)

# 3. Meeting point — published — description + comment
create_poi.(
  %{
    name: "Central Meetup",
    category: :meeting_point,
    description: "Default rendezvous point in the centre lawn. Meet here if plans change.",
    comment: "Hourly check-ins at :00",
    location: point.(18.0741, 59.3430),
    event_id: event.id
  },
  true
)

# 4. Food — published — description + comment
create_poi.(
  %{
    name: "Fika Station",
    category: :food,
    description: "Coffee, tea, and cinnamon rolls. Open 08:00–18:00 daily.",
    comment: "Oat milk available on request",
    location: point.(18.0761, 59.3421),
    event_id: event.id
  },
  true
)

# 5. Hazard — published — description only
create_poi.(
  %{
    name: "Slippery Path",
    category: :hazard,
    description: "Cobblestone path becomes very slippery when wet. Watch your step near the fountain.",
    location: point.(18.0776, 59.3441),
    event_id: event.id
  },
  true
)

# 6. Other — published — comment only (no description — empty desc state)
create_poi.(
  %{
    name: "Info Board",
    category: :other,
    comment: "Schedule and area map posted daily at 07:30",
    location: point.(18.0731, 59.3435),
    event_id: event.id
  },
  true
)

# 7. Meeting point — draft — description only
create_poi.(
  %{
    name: "Backup Meetup",
    category: :meeting_point,
    description: "Fallback rendezvous near the north gate if Central Meetup is at capacity.",
    location: point.(18.0721, 59.3444),
    event_id: event.id
  },
  false
)

# 8. Viewpoint — draft — no description or comment (empty state)
create_poi.(
  %{
    name: "East Overlook",
    category: :viewpoint,
    location: point.(18.0791, 59.3441),
    event_id: event.id
  },
  false
)

# 9. Food — published — description only
create_poi.(
  %{
    name: "Water Point",
    category: :food,
    description: "Free drinking water refill station. Bring your own bottle.",
    location: point.(18.0756, 59.3411),
    event_id: event.id
  },
  true
)

# 10. Camp — published — description only
create_poi.(
  %{
    name: "Emergency Shelter",
    category: :camp,
    description: "Emergency shelter with first-aid kit. Staffed during all event hours.",
    location: point.(18.0703, 59.3451),
    event_id: event.id
  },
  true
)

IO.puts("  10 POIs created (8 published, 2 draft)")

# ── Summary ───────────────────────────────────────────────────────────────────

IO.puts("""

Demo seeds complete!
  Event:       #{event.name}
  Join code:   #{demo_join_code}
  Event ID:    #{event.id}
  Map URL:     /events/#{event.id}/map

Demo users (is_simulated: true):
  demo-admin@dev.local  — admin
  demo-alice@dev.local  — member
  demo-bob@dev.local    — member

GPS Simulator route waypoints
(copy into IEx or the simulator UI after setting the event to #{event.id}):

  perimeter_patrol = #{inspect(perimeter_patrol)}

  food_run = #{inspect(food_run)}

  camp_check = #{inspect(camp_check)}
""")
