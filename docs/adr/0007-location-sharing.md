# ADR-0007: Live Location Sharing — Browser Geolocation API + Phoenix Presence

## Status
Accepted

## Context
A key feature is seeing where all event participants are on the map in real time. The
application is mobile-first and must work in the browser (no native app). Location sharing
must be opt-in and have a clear UI affordance to stop sharing.

## Decision
Use the **Browser Geolocation API** (`navigator.geolocation.watchPosition`) on the client,
combined with **Phoenix Presence** on the server.

### Client-side (MapLibre hook)
- On opt-in, call `navigator.geolocation.watchPosition` with:
  - `enableHighAccuracy: true`
  - `maximumAge: 5000`
  - `timeout: 10000`
- Throttle pushes to server: send a location update only if position changed by > 10 m
  **or** 10 seconds have elapsed since last push.
- Push via `this.pushEvent("location_update", {lat, lng, accuracy, heading})` in the hook.

### Server-side
- LiveView `handle_event("location_update", ...)` updates the user's metadata in
  `Phoenix.Presence` on topic `event:{id}:locations`.
- `handle_info` on presence diff broadcasts to all subscribers via PubSub, triggering
  map marker updates in other connected clients' MapLibre hooks.
- Positions are **not persisted to the DB** — live display is the only use case (replay/
  history is out of scope per ADR-0000). Presence metadata is lost on node restart, which
  is acceptable for the MVP.

### Geofence entry/exit detection
After updating Presence, the LiveView queries PostGIS for all public geofences the user is
currently inside (`ST_Within`). The previous membership set is read from the user's existing
Presence metadata. Transitions (enter or exit) trigger an `Activity.Entry` insert and a
PubSub broadcast. See ADR-0002 for the PostGIS query detail.

### Why Phoenix Presence (not a custom ETS store)
Presence is the right tool here because:
- It **automatically cleans up** stale position markers when a user disconnects — critical
  for UX (no ghost markers for users who left).
- Position data and online status are co-located in one metadata map.
- At the target scale (≤20 users, updates every 5–10 s) the `presence_diff` broadcast
  volume is negligible (≤4 broadcasts/second total).

### Privacy
- Location sharing is **opt-in** per event session. Default is off.
- A visible indicator on the map UI shows whether you are currently sharing.
- Stopping the LiveView (navigating away) automatically cleans up via Presence.

## Consequences
- **Positive:** No native app required. Presence handles disconnect cleanup automatically.
  Throttling prevents flooding PubSub with GPS noise.
- **Negative:** Browser Geolocation requires HTTPS in production (localhost exempt in dev).
  Background location tracking stops when the browser tab is hidden on some mobile platforms.
