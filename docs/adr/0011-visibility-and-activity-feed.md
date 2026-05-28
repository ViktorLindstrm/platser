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
