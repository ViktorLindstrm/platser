# ADR-0013: POI Creation UI State Machine

## Status
Accepted

## Context
Creating a POI requires a multi-step flow that combines map interaction (picking a location)
with form input (name, description, category, photos). The LiveView must coordinate:

1. Entering "location picking" mode — cursor changes, map click is intercepted.
2. Receiving the picked coordinates from the JS hook.
3. Showing the detail form as a bottom sheet.
4. Uploading files and submitting to the backend.

A single `show_form` boolean flag is insufficient because the map and JS hook need to be
placed in different modes independently.

## Decision
Use a `poi_step` socket assign as an explicit **step enum** tracking the creation wizard:

| Value | Description |
|-------|-------------|
| `:idle` | No creation in progress; normal map interaction. |
| `:picking` | User is selecting a location; cursor is crosshair, map click captured. |
| `:editing` | Location is set; detail form (bottom sheet) is visible. |

### Transitions

```
:idle  →[click "Add POI"]→  :picking
:picking  →[poi_location_picked event from JS]→  :editing  (with location stored in @poi_location)
:picking  →[cancel]→  :idle
:editing  →[cancel]→  :idle
:editing  →[save draft / publish]→  :idle  (after server-side persist)
```

### JS ↔ LiveView coordination
- LiveView pushes `push_event(socket, "enable_location_pick", %{})` when entering `:picking`.
- LiveView pushes `push_event(socket, "disable_location_pick", %{})` when leaving `:picking`.
- The `MapHook` JS hook listens for these events and toggles `this.pickMode`.
- When `pickMode` is true, map click pushes `poi_location_picked` with `{lat, lng}` to the server.
- The server transitions to `:editing` and stores `%Geo.Point{coordinates: {lng, lat}, srid: 4326}`.

### Location storage
`poi_location` is stored as a socket assign (`%Geo.Point{}`), not as a form field. It is passed
directly into the Ash `create` call, bypassing `AshPhoenix.Form` for the geometry field (form
does not support `Geo.Point` serialization from HTML inputs).

## Consequences
- **Positive:** The state enum makes all possible UI states explicit and exhaustive. The JS
  hook is told exactly when to capture clicks — no guessing based on DOM state. Cancellation
  from any step is handled cleanly by resetting to `:idle`.
- **Negative:** The step enum must be kept in sync with JS event handling. Any new step
  (e.g., `:drawing_geofence`) must add corresponding `push_event` logic in both LiveView and
  the map hook.
