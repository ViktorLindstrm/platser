# ADR-0016: Map Item Inspection Drawer

## Status
Accepted

## Context
The map now needs a direct inspection surface for both POIs and geofences. Users should be able to tap or click a visible map item, review its state, and then decide whether to focus, publish, or delete it without leaving the map.

The existing map already exposes POI and geofence features as GeoJSON layers, and the LiveView already owns the canonical item data. The missing piece was a shared selection state plus a consistent review drawer for both resource types.

## Decision
Use a single map inspection drawer driven by a `selected_map_object` socket assign.

- The MapLibre hook emits an `inspect_map_object` event when a POI circle or geofence layer is clicked.
- The LiveView resolves the selected resource, stores it in `selected_map_object`, and renders a shared drawer.
- The drawer shows kind, status, visibility, metadata, and item-specific review copy.
- A `focus_selected_map_object` action recenters the map on the selected geometry.
- Publish/delete actions are exposed only when the current actor can manage the selected item.

### Hover affordance

To signal that map items are interactive, the hook adds a `mousemove` listener on the map canvas
that queries rendered features on the three interactive layers (`poi-circles`, `geofence-fills`, `geofence-lines`).

- When the pointer is over an interactive feature the canvas cursor is set to `"pointer"`.
- A small name tooltip (`maplibregl.Popup` with `className: "poi-hover-popup"`) appears at the
  cursor position using `setText` (never `setHTML`) to avoid XSS.
- The cursor and tooltip are suppressed during pick mode and draw mode, which use the `"crosshair"` cursor.
- The `mousemove`-based query is preferred over per-layer `mouseenter`/`mouseleave` to avoid
  double-firing issues when `geofence-fills` and `geofence-lines` overlap.
- Hover is a desktop-only affordance; mobile users access items via tap (the existing click handler).

## Consequences
- POIs and geofences share one browsing model instead of separate ad-hoc overlays.
- The drawer makes draft/public state explicit without leaving the map.
- Management actions stay aligned with Ash policies while keeping the interaction surface small.
- The selection state must stay in sync with the JS hook and the update events that mutate map features.
- The hover tooltip relies on the `name` property always being present in GeoJSON feature payloads;
  this invariant is enforced by `allow_nil? false` on the name attribute of both `Poi` and `Geofence` resources.

