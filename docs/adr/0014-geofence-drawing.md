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
