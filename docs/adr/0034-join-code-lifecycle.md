# ADR-0034: Join Code Lifecycle Hardening

## Status

Accepted

## Context

ADR-0005 established short event join codes and regeneration, while ADR-0026 kept public
lookup by valid join code for low-friction guest onboarding. ADR-0033 added throttling for
join-code guessing at the Phoenix route boundary.

P1 hardening requires join codes to have explicit lifecycle state so administrators can rotate
or invalidate codes and expired codes cannot be used through public routes, forms, or lower-level
domain actions.

## Decision

Store join-code lifecycle metadata directly on `Platser.Events.Event`:

- `join_code_expires_at` is the active code expiry timestamp. New and regenerated codes expire
  at the event `ends_at` timestamp.
- `join_code_rotated_at` records when the current code was issued.
- `join_code_invalidated_at` records administrative invalidation without deleting the last code.

`Event.get_by_join_code` only returns events when the provided code matches the current code, the
code is not invalidated, and `join_code_expires_at > now()`. `Membership.join` resolves events
through that same action, so direct LiveView joins, guest controller joins, and lower-level
`Events.join_event/2` calls share one lifecycle guard.

Administrators can regenerate a code or invalidate the current code from the event dashboard.
Regeneration issues a replacement, clears invalidation, updates rotation time, and keeps existing
memberships. Invalidation disables future joins without removing existing members and leaves
timestamped metadata for audit-friendly inspection.

The route-level join rate limiter from ADR-0033 remains in front of the public join endpoints.
Lifecycle rejection must not bypass or weaken throttling.

## Consequences

- Expired, rotated, and invalidated codes fail uniformly as invalid or expired invites.
- Event admins have a reversible way to close invitations: invalidate now, regenerate later.
- Existing members keep access because membership authorization remains separate from invite
  lifecycle state.
- Code expiry follows event end time for now; future work can add a separate admin expiry editor
  if events need invitation windows that differ from the event schedule.
