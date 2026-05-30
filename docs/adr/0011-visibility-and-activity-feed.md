# ADR-0011: Visibility Model & Activity Feed

## Status
Accepted

## Context
Event participants can create POIs and geofences that are either private (only visible to
themselves and the event admin) or public (visible to all members). When a public object
is created or published, all members should be notified via a live activity feed —
"be very vocal when we do a thing that is shared."

## Decision

### Visibility model
- Every `Map.Poi` and `Map.Geofence` has a `visibility` field: `:public` or `:private`.
- Default on creation is `:private` (draft state).
- Publishing (setting `visibility: :public` and `published_at: DateTime.utc_now()`) is an
  explicit Ash action: `Poi.publish/1`, `Geofence.publish/1`.
- Ash policies enforce read access:
  - `:public` objects → visible to all event members.
  - `:private` objects → visible only to `creator_id` and users with role `:admin` in the event.

### Activity feed
- On every `publish` action, an `Activity.Entry` record is inserted and a PubSub broadcast
  is sent on `event:{id}:activity`.
- Feed entry examples:
  - *"Alice published a POI: Great Viewpoint 🏔"*
  - *"Bob added a camp area: Base Camp"*
  - *"Carlos joined the event"*
  - *"Diana entered Base Camp"*
  - *"Erik left Restricted Zone"*
- The LiveView renders a **slide-up drawer** (mobile) or **side panel** (desktop) showing
  the last 50 activity entries, newest first.
- New entries animate in with a subtle slide + fade transition.
- Unread badge count is shown on the feed toggle button.

### Notifications on the map
- When a new public POI or geofence is created, a toast notification appears on the map view
  for all connected members: *"New POI from Alice — tap to zoom"*.
- Tapping the toast flies the map to the object's location.

## Consequences
- **Positive:** Clear separation between draft (private) and published (public) states
  prevents accidental sharing. Activity feed creates a sense of shared presence even when
  users are in different locations.
- **Negative:** Feed can be noisy during active collaboration sessions. Future work:
  notification preferences / mute.

## Amendment: Unified, filterable activity panel (task #39)

The activity drawer now includes filter chips for all, check-ins, geofence events, published
items, and comments. Comment saves create `comment_added` activity entries so the feed and the
inspection drawer can share the same activity model.

## Amendment: joined_event activity entries (task #42)

When a user joins an event via `Events.join_event/2`, a `:joined_event` `Activity.Entry` is
created automatically by `Platser.Events.Changes.BroadcastJoin` — an `after_transaction` change
on the `Membership` resource's `:join` action. This keeps the activity-entry concern in the
domain layer (not in the LiveView) and is consistent with how POI/geofence publish events are
captured via `BroadcastPublish` / `BroadcastGeofencePublish`.

The admin membership created at event creation time does **not** go through the `:join` action
and therefore does not produce a `:joined_event` entry.

The entry always carries `subject_type: "user"` and `subject_id: actor.id`, and is broadcast on
`event:{id}:activity` so connected LiveViews update the feed in real time.
