# ADR-0019: Persistent Event Check-Ins

## Status
Accepted

## Context

The map already supports live location sharing through Phoenix Presence, which is transient by
design. We also need a one-shot "Check In" action that records a user's location at a moment in
time so other event members can see recent arrivals even after reconnects or page reloads.

## Decision

Add a persisted `Activity.Entry` action for check-ins and store the coordinates on the entry
itself.

### Data model

- Add nullable `lat` and `lng` attributes to `Activity.Entry`.
- Add a new `:checked_in` action on `Activity.Entry`.
- Keep existing activity entries valid even when coordinates are absent.
- Validate check-in coordinates as WGS-84 floats:
  - `lat` in `[-90, 90]`
  - `lng` in `[-180, 180]`

### UX flow

- The map shows a dedicated "Check In" button.
- Clicking it requests the browser's current position once via `navigator.geolocation.getCurrentPosition`.
- The client sends the coordinates to the LiveView through `check_in`.
- The server creates a persisted activity entry, broadcasts it on `event:{id}:activity`, and
  pushes a marker update back to the map hook.
- Recent check-ins are included in `map_init` so they reappear after reloads.

### Separation from live sharing

- **Live location sharing** continues to use Presence and remains ephemeral.
- **Check-ins** are persisted history and are intended for notable moments, not continuous tracking.
- This keeps the live map responsive while preserving a lightweight audit trail of arrivals.

## Consequences

- **Positive:** Users can mark arrival without enabling continuous location sharing.
- **Positive:** Check-ins survive reconnects and page reloads.
- **Negative:** The map now tracks both transient live markers and persisted check-in markers, so the
  UI and JS hook must manage two marker sets.
