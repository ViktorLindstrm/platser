# ADR-0017: Event Map Bounds

## Status

Accepted

## Context

The event map loads at a hardcoded center and zoom level (Auckland, NZ, zoom 12), which is irrelevant
for most events. When multiple events exist in different geographic locations the map should
auto-focus to the event's area on load. Event admins need a way to define the geographic scope of
their event.

## Decision

Store optional bounds as a `Geo.Polygon` rectangle (SRID 4326) on the `Events.Event` resource.
Bounds can be set or updated by event admins from within the map view by saving the current viewport.

### Data model

- Add nullable `bounds` attribute of type `Platser.Types.Geometry` to `Events.Event`.
- Add `:set_bounds` update action, restricted to event admins via Ash policy.
- Migration: `add :bounds, :geometry, srid: 4326, null: true` on the `events` table.

### UX flow

- Bounds are **not required** at event creation — the field stays `nil` for new events.
- On the map view, event admins see a "Set map area" FAB button alongside the existing controls.
- Clicking it captures the current MapLibre GL JS viewport bounds and pushes them to the server
  via the `save_map_bounds` Phoenix LiveView event as `{west, south, east, north}` floats.
- The server validates the incoming coords (finite numbers, `south < north`) and stores the
  bounding rectangle as a `Geo.Polygon` with SRID 4326.
- After a successful save, the server pushes a `fit_bounds` event back so the map re-fits.
- On **every map load**, if `event.bounds` is set it is included in the `map_init` payload as
  `{west, south, east, north}` floats and the JS hook calls `fitBounds` with 40 px padding.

### Map initialization fallback chain (task #45)

When `map_init` is sent, the server computes bounds using this priority:

1. **Explicit bounds**: If the event has a `bounds` field set by an admin, use it.
2. **Fallback bounds from objects**: If no explicit bounds exist, compute a bounding box from:
   - All POI locations (`Geo.Point` coordinates)
   - All geofence geometries (extract coordinates from `Geo.Polygon`, `Geo.LineString`, or `Geo.Point`)
   - If any objects exist, fit the map to their collective bounding box.
3. **Hardcoded default**: If an event has no bounds and no map objects, the map uses the hardcoded
   center/zoom (currently Auckland, NZ at zoom 12). This ensures a usable fallback for empty events.

The `map_init` payload always includes a `bounds` key: either from explicit bounds, computed from
objects, or `nil` to trigger the hardcoded default. The JS hook checks `if (bounds)` before calling
`fitBounds`, allowing graceful fallback.

### JS hook changes

- `map_init`: if `bounds` is present in the payload, call
  `map.fitBounds([[west, south], [east, north]], {padding: 40, duration: 0})` immediately after
  sources are initialised.
- New `fit_bounds` event handler: same `fitBounds` call with `duration: 450` (animated).
- Document-level click delegation keyed on `data-set-map-area` captures the viewport and pushes
  `save_map_bounds`; the listener is cleaned up in `destroyed()`.

## Consequences

- Events in any location auto-focus correctly instead of always defaulting to Auckland.
- Admins can set explicit bounds without leaving the map, or leave it unset for auto-fit behavior.
- New events with POIs/geofences automatically fit the map to show all objects on first load.
- Events with no objects fall back to a sensible default instead of attempting to fit non-existent data.
- Bounds are optional — admins retain full control over the initial viewport.
- Storing bounds as a `Geo.Polygon` allows future spatial queries
  (e.g., filtering POIs that fall outside event bounds).

