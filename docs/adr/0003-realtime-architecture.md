# ADR-0003: Real-time Architecture — Phoenix PubSub + LiveView

## Status
Accepted

## Context
The application requires live collaboration: all participants in an event see map updates
(new POIs, geofences, member positions) as they happen, without polling or page refresh.

## Decision
Use **Phoenix PubSub** for server-side broadcast and **Phoenix LiveView** for pushing updates
to connected clients.

### Topic namespacing
Each event gets a dedicated PubSub topic: `event:{event_id}`.

Sub-topics for scoping:
- `event:{id}:locations` — live member GPS positions (high frequency, ~5 s interval)
- `event:{id}:map_objects` — POI / geofence create / update / delete
- `event:{id}:activity` — activity feed entries (public actions)

### Flow
1. Client LiveView subscribes to relevant topics on `mount`.
2. Domain actions (create POI, update geofence, publish location) broadcast via
   `Phoenix.PubSub.broadcast/3` after the Ash action succeeds.
3. LiveView `handle_info/2` receives the broadcast and either updates assigns or pushes
   a client-side event via `push_event/3` to the MapLibre JS hook.

### Location updates
User positions are **not persisted** to the DB at high frequency. The latest position per
user per event is held in `Phoenix.Presence` metadata in memory. Positions are **not**
written to the DB during normal operation — live position display is the only use case in
scope (see ADR-0000: replay/history is explicitly a non-goal for the MVP).
See ADR-0007 for the full location-sharing implementation detail.

## Consequences
- **Positive:** No WebSocket infrastructure beyond what Phoenix provides out of the box.
  LiveView handles reconnection and state recovery automatically.
- **Negative:** In-memory position state is lost on node restart (acceptable for MVP; can add
  Redis-backed Presence later). High-frequency location broadcasts from many users require
  throttling on the client side.
