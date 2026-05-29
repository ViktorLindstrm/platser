# ADR-0014: Geofence Drawing

## Status

Accepted

## Context

Task #8 requires a polygon draw mode on the event map that lets event staff create named, colour-coded geofences. Geofences must be saved as Ash 3.0 resources, go through the same private → public visibility lifecycle as POIs (ADR-0011), and render as filled polygons on the MapLibre GL JS map.

Key design questions:

1. **Where is the canonical vertex list stored?** — server (LiveView) or client (JS) only?
2. **How is the in-progress polygon previewed?** — pure client-side layers or round-trip to server?
3. **How is geometry validity enforced?** — in the UI, in the Ash resource, or both?
4. **How are geofences broadcast on publish?** — same PubSub/Activity pattern as POIs, or different?

## Decision

### 1. Vertex ownership: server is canonical

Every time the user clicks the map to add a vertex the JS hook immediately pushes a `vertex_added` event to the LiveView, carrying the full accumulated vertex list (`[[lng, lat], ...]`). The LiveView assigns the list to socket state. This means:

- No state divergence between client and server.
- Undo ("remove last vertex") is handled by the LiveView: it pops the list and pushes `disable_draw_mode` + `enable_draw_mode` with the new list, letting JS repaint.
- No vertex state is lost on a LiveView reconnect.

### 2. Draw preview: pure client-side MapLibre layers

While the user is drawing, the polygon preview (dashed outline + vertex circles + translucent fill) is rendered exclusively by the JS hook via three MapLibre source/layer pairs (`draw-preview`, `draw-fill`, `draw-outline`, `draw-vertices`). This gives fluid, frame-rate animation with no round-trip latency.

The layers are created on `enable_draw_mode` and torn down on `disable_draw_mode`.

### 3. Geometry validation in the Ash resource

Validation is enforced in the `Platser.Map.Geofence` resource's `create` action via inline `validate` lambdas:

- **Polygon geometry**: must be `%Geo.Polygon{}` with a closed ring of ≥ 4 coordinate pairs (3 distinct vertices + repeated first point).
- **Hex colour**: must match `~r/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/`.

The LiveView also enforces a minimum vertex count in the UI (Finish button disabled until ≥ 3 vertices), but the Ash-level check is the authoritative gate.

### 4. Publish lifecycle — same as POI

`Platser.Map.Geofence` follows the same `private → public` visibility lifecycle defined in ADR-0011:

- `create` sets `visibility: :private`.
- `publish` validates `visibility == :private` (idempotency guard), sets `visibility: :public` and `published_at: DateTime.utc_now()`, then runs `BroadcastGeofencePublish`.
- `BroadcastGeofencePublish` (after-transaction change) broadcasts `{:geofence_added, geofence}` on `event:{id}:map_objects` PubSub and creates an `Activity.Entry` with `action: :geofence_published`.

### 5. LiveView state machine

The geofence draw flow uses a three-state atom `:geofence_step`:

| State | Description |
|-------|-------------|
| `:idle` | Default — no draw or form visible |
| `:drawing` | User is clicking vertices on the map |
| `:editing` | Polygon closed; user fills in name/purpose/colour form |

FAB buttons are hidden when either `geofence_step != :idle` or `poi_step != :idle`.

### 6. Jason.Encoder for Geo types

Elixir 1.18+ ships a built-in `JSON` module, so the `geo` hex package conditionally implements `JSON.Encoder` instead of `Jason.Encoder`. Ash uses Jason internally for attribute serialisation, causing `Protocol.UndefinedError` at runtime. The fix is to add explicit `Jason.Encoder` implementations for all `Geo.*` struct types in `lib/platser/types/geometry.ex`, delegating to `Geo.JSON.encode!/1`.

## Consequences

- **New resource**: `Platser.Map.Geofence` gains `create` + `publish` actions, `published_at` attribute, and Ash-side geometry/color validators.
- **New migration**: `priv/repo/migrations/20260529101854_add_geofence_published_at.exs`.
- **New change module**: `Platser.Map.Changes.BroadcastGeofencePublish`.
- **Property tests**: `test/platser/geofence_property_test.exs` covers vertex count rejection, valid purpose enumeration, publish idempotency, and hex colour validation.
- **Geometry type fix**: `cast_input` and `cast_stored` in `Platser.Types.Geometry` now handle GeoJSON maps (in addition to native PostGIS values) to survive Ash's internal JSON serialisation round-trip.
- **Mutually exclusive modes**: POI pick mode and geofence draw mode cannot be active simultaneously; one cancels the other.

## Amendment: Form field parity with POI (task #32)

**Status: Implemented**

To make the boundary creation experience consistent with POI creation:

### 7. Geofence form adds description and photo upload

The geofence creation/edit form gains two fields that match the POI form:

- **Description** — optional free-text `textarea` (`description` attribute, `allow_nil?: true`).
- **Photo upload** — same `allow_upload(:photos, …)` LiveView upload configuration as POIs; attachments are stored via `Media.Attachment` and associated with the geofence record via `geofence_id` FK.

The `<.live_file_input>` is conditionally rendered only when the respective form is active (`@poi_step == :editing` / `@geofence_step == :editing`) to prevent duplicate DOM IDs from both forms being present simultaneously.

Geofences keep their existing unique fields (purpose radio group, colour picker). Field order in the sheet:

1. Polygon indicator / vertex count
2. Name *
3. Description
4. Photos (new geofences only)
5. Purpose (hidden when editing a published geofence)
6. Colour

### 8. Data model additions

- `description` column added to `geofences` table (`:string`, nullable).
- `comment` column added to `geofences` and `pois` tables (`:string`, nullable).
- `geofence_id` FK column added to `media_attachments` table (`references :geofences`, `on_delete: :delete_all`).
- `poi_id` made nullable in `media_attachments` to support the exclusive-parent model.
- A DB check constraint `exactly_one_parent` enforces `(poi_id IS NOT NULL AND geofence_id IS NULL) OR (poi_id IS NULL AND geofence_id IS NOT NULL)`.
- `has_many :attachments` added to `Platser.Map.Geofence` with `destination_attribute: :geofence_id`.
- `Media.Attachment` gains two new Ash actions: `list_by_geofence` and `create_for_geofence`.
- `Platser.Media` domain gains `list_attachments_for_geofence/2` and `create_geofence_attachment/2` public functions.
- Photo upload paths use the geofence ID as the subdirectory (same pattern as POI: `/uploads/<geofence_id>/<uuid>_filename`).
- All changes are in incremental migration `priv/repo/migrations/20260529202707_task32_geofence_ux_parity.exs`.
- Property tests in `test/platser/geofence_property_test.exs` extended to cover: description stored on create, comment persisted via `update_metadata`, attachment XOR-parent constraint, and geofence attachment list.
