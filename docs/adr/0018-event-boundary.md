# ADR-0018: Event Boundary Geofence

## Status

Accepted

## Context

Events need one authoritative polygon that represents the official event territory. That polygon
must drive the "in event area" presence chip, remain visible to everyone, and be easy for admins to
inspect and fit the map to. It should not behave like an ordinary draft geofence.

## Decision

Use `purpose: :boundary` geofences as the official event territory marker.

### Rules

- An event can have at most one boundary geofence.
- Boundary geofences are public as soon as they are created.
- Boundary geofences reuse the same publish side effects as a normal publish, so map objects and
  activity feeds stay in sync.
- Boundary geofences are surfaced specially in the map UI:
  - no publish/draft toggle
  - a boundary-specific "fit to boundary" action
  - an "In event area" chip when the current shared location falls inside the boundary

### Enforcement

- Partial unique index on `geofences(event_id)` where `purpose = 'boundary'`.
- Ash validation on create/update to prevent a second boundary for the same event.
- Boundary presence checks use the boundary geofence ID rather than generic geofence membership.

### Consequences

- The boundary becomes the single source of truth for event territory.
- Presence/location UX can rely on a simple boolean instead of inferring area from multiple shapes.
- Regular geofences keep their existing draft/publish lifecycle.
