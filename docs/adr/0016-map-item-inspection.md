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

## Post-creation auto-inspect

After a successful POI or geofence creation (both draft and publish paths), the inspection drawer
opens automatically for the newly created item. This is implemented by calling `select_map_object/3`
in `do_create_poi` and `do_create_geofence` immediately after `reset_poi_form`/`reset_geofence_form`.
This means:

- The creation form bottom sheet closes (step reset to `:idle`).
- The inspection drawer opens showing the new item's status, visibility, and available actions.
- The user can immediately publish, edit, or delete the item without tapping it on the map.
- For the publish path, `selected_map_object` is populated with the *published* version of the item
  (the post-publish result), ensuring the correct status badge and hidden publish button are shown.

## Amendment: Unified drawer and comment field (task #32)

**Status: Implemented**

### Unified drawer layout for POI and geofence

The inspection drawer shows an identical structure for both POIs and geofences:

1. **Header** — kind icon, kind label, item name, close button
2. **Status badges** — visibility (draft/public) and kind badge
3. **Description** — shown for both POI and geofence when present (previously POI-only)
4. **Photo gallery** — shown for both kinds when attachments are present (previously POI-only)
5. **Metadata grid** — kind-specific fields (POI: category + coordinates; geofence: purpose + vertex count)
6. **Comment** — editable multi-line field for inline notes (see below)
7. **Action bar** — Focus, Publish, Edit, Delete buttons (unchanged)

### Comment field replaces Review section

The static "Review" section (which displayed "This item is public and visible…" copy) is removed.

In its place, an editable **Comment** field is rendered directly in the drawer:

- Displayed as a `<textarea>` for both POI and geofence items with id `map-item-comment`.
- Saved on blur via a `save_map_object_comment` LiveView event (no debounced change, to avoid cursor-jump).
- Stored in a new `comment` attribute (`allow_nil?: true, :string`) on both `Poi` and `Geofence` resources.
- The textarea is `disabled` for non-managers (`@selected_map_object_can_manage == false`).
- No separate publish step — the comment is always saved as a plain mutable field and is not gated by visibility.
- Draft/public status information is still surfaced via the existing status badge, not as freeform text.

## Photo gallery in inspection drawer

The `selected_map_object` assign includes an `attachments` field: a list of `Media.Attachment`
records loaded for both POIs and geofences.

- `load_selected_map_object/3` calls `load_poi_attachments/2` when selecting a POI, and `load_geofence_attachments/2` when selecting a geofence.
- `select_map_object/3` does the same for the post-creation auto-inspect path.
- `publish_selected_map_object` now uses `select_map_object/3` so attachments are reloaded
  after publishing (keeping the gallery visible after status transitions).
- A horizontally-scrolling photo strip (id `map-item-photo-strip`) is rendered inside the drawer when
  `@selected_map_object.attachments != []` for either kind.
- Photos link to their stored path and open in a new tab. File access is not gated
  by an authenticated route — the `/uploads/...` paths are served by `Plug.Static`.
  This is an acceptable trade-off for local dev (per ADR-0009); paths include a UUID
  prefix making them opaque to guessing. Production deployments should replace
  `Plug.Static` serving with signed CDN URLs.
- Attachments in `list_by_poi` and `list_by_geofence` are sorted by `inserted_at asc` for deterministic order.

## Amendment 2: Compact metadata, image carousel, creator line (task #34)

**Status: Implemented**

### Removed: Big category/purpose cards and raw coordinates

The metadata grid (showing category label, visibility, and raw latitude/longitude for POI; purpose and vertex count for geofence as separate large cards) has been removed. Raw coordinates are not useful to end users.

### Compact category/purpose chip

Category (POI) and purpose (geofence) are now shown as a compact inline chip in the badge row alongside the status badge:

- POI chip includes the category icon and human-readable label (e.g., 🏕 camping).
- Geofence chip includes a small color swatch (using the geofence's `color` hex value) and the purpose label.
- Geofence vertex count is shown as a plain `pts` stat inline in the same row.

### Creator and published date row

A new "Added by" line is rendered below the badge row:
- Shows `item.creator.display_name` when the creator relationship is loaded.
- If `item.published_at` is present, appends "· Published DD Mon YYYY" using `Calendar.strftime`.
- Loaded in both `load_selected_map_object/3` and `select_map_object/3` via a new `load_item_creator/2` helper.
- On load failure (policy denial, error), the item is returned unchanged and a warning is logged; the row is simply omitted.

### Image carousel replaces horizontal scroll strip

The photo strip (`#map-item-photo-strip`, horizontal overflow scroll) is replaced by a full-width slide carousel (`#map-item-carousel`):

- CSS `translateX` approach — a `[data-track]` flex container slides via transform on prev/next arrow clicks.
- Dot indicators update their opacity to show current position.
- Touch swipe supported via `touchstart`/`touchend` delta detection.
- Implemented as a colocated Phoenix LiveView hook (`.Carousel`).
- The hook uses a `data-item-key={"kind-id"}` attribute to detect item changes in `updated()` and only reset the slide index when the item changes (not on every LiveView patch).

### Visibility badge removed

The separate `#map-item-visibility-badge` element is removed. The draft/published distinction is fully conveyed by the `#map-item-status-badge` color (amber = draft, emerald = published). Visibility information is no longer shown as a separate badge.

### Comment visibility for non-managers

Non-managers only see the comment if it is non-empty; if empty it is hidden entirely. Managers always see the editable textarea. This prevents the UI from showing a blank input field for read-only participants.

### Promoted Publish button

The Publish button is now rendered in its own full-width row above the focus/edit/delete action bar, making it the primary CTA when a draft item is selected.
