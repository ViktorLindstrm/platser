# ADR-0027: Additive Map Comments

## Status
Accepted

## Context
Map item comments were implemented as a singleton text field on `Poi` and `Geofence`, edited in
place from the inspection drawer. This forced an overwrite model ("latest wins") instead of a real
conversation and made it impossible to add multiple comments over time.

The requirement is to support additive comments in the map inspection experience while keeping the
existing activity feed behavior.

## Decision
- Treat each map comment as an `Activity.Entry` with action `:comment_added`.
- Replace the inspection drawer's blur-to-save singleton textarea with an explicit comment form
  (`phx-submit`) and an "Add comment" action.
- Keep the per-item comments list as a live stream sourced from the selected item's
  activity entries filtered to `:comment_added`.
- Keep the event-level activity feed unchanged; comment entries continue to flow through the same
  PubSub topic (`event:{id}:activity`) and are visible in the feed.
- Keep `Poi.comment` and `Geofence.comment` columns for backward compatibility; the map UI no
  longer writes to these fields.

## Consequences
- Users can add multiple comments instead of overwriting a single comment.
- Comments and activity now share one append-only event model, which improves realtime consistency.
- Existing historical singleton comment text in `pois.comment` / `geofences.comment` is not used by
  the new UI; migration/backfill can be handled separately if needed.

## Amendment: end-to-end review hardening (task #57)

- The map inspection experience intentionally supports **add-only** comments.
  - Supported: add new comment entries (`:comment_added`).
  - Unsupported: edit existing comments, delete existing comments.
- Subject comment queries are scoped by **subject id + subject type + event id** to prevent
  cross-event or cross-type leakage in the inspection drawer.
- Comment entry creation now requires event membership for the actor at authorization time
  (system/internal flows may still use explicit `authorize?: false` where intended).
