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
  `{west, south, east, north}` floats and the JS hook calls `fitBounds` with 40 px padding;
  otherwise the map stays at the default center/zoom.

### JS hook changes

- `map_init`: if `bounds` is present in the payload, call
  `map.fitBounds([[west, south], [east, north]], {padding: 40, duration: 0})` immediately after
  sources are initialised.
- New `fit_bounds` event handler: same `fitBounds` call with `duration: 450` (animated).
- Document-level click delegation keyed on `data-set-map-area` captures the viewport and pushes
  `save_map_bounds`; the listener is cleaned up in `destroyed()`.

## Consequences

- Events in any location auto-focus correctly instead of defaulting to Auckland.
- Admins can update bounds at any time without leaving the map.
- Bounds are optional — existing events without bounds fall back to the hardcoded default.
- Storing bounds as a `Geo.Polygon` allows future spatial queries
  (e.g., filtering POIs that fall outside event bounds).
