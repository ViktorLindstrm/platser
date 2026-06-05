# ADR-0020: Unified Activity + Comments Panel

## Status
Accepted

## Context
The map already had a noisy, realtime activity drawer and a separate inspection drawer with a
comment field. That split made it hard to see item-specific history, and comment updates were not
part of the same stream as published events and check-ins.

## Decision
- Keep a single realtime activity drawer for the whole event.
- Add server-side filter chips for all, check-ins, geofence events, published items, and comments.
- Reset the stream from the server when the filter changes; do not filter LiveView streams in place.
- Create `comment_added` activity entries whenever a POI or geofence comment is saved.
- Load per-item activity by subject id in the inspection drawer and stream new matching entries into
  that drawer in realtime.
- Render the current comment as a pinned quoted block above the per-item activity list.

## Consequences
- Comments and activity are now modeled consistently.
- The inspection drawer gives immediate context without leaving the map.
- The feed stays realtime while still allowing the user to reduce noise with filters.

## Amendment: additive comments (task #56)

The original implementation still used singleton `poi.comment` / `geofence.comment` editing in the
drawer. This was superseded by ADR-0027, which moves the drawer UX to additive comments and stores
each comment as an append-only `Activity.Entry` (`:comment_added`).
