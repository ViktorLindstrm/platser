# ADR-0037: Account Deletion and Anonymization

## Status

Accepted

## Context

Task #63 requires a self-service deletion flow that follows the DSAR inventory in
ADR-0036. User-linked event history must remain referentially safe because memberships,
events, map objects, activity entries, and media metadata all use `users.id` foreign keys.
Authentication uses stored AshAuthentication tokens, so deletion must also invalidate
existing browser sessions and future sign-in.

## Decision

Account deletion is implemented as anonymization of the `users` row rather than physical
deletion. The row is kept as a tombstone so historical records can continue to reference a
valid user id. The account row is changed to:

- a synthetic non-deliverable `deleted_<user_id>@platser.deleted` email,
- display name `Deleted user`,
- `hashed_password: nil`,
- `is_guest: false`,
- `superuser: false`,
- `deleted_at` set to the deletion time.

All stored authentication token rows whose subject belongs to the user are removed. Because
the application requires token presence for authentication, existing sessions no longer
resolve to an authenticated user and the original email cannot be used for future sign-in.

User-authored historical records are preserved, but direct personal content in privacy
sensitive fields is minimized:

- activity entry messages authored by the user are replaced with `[deleted account]`,
- activity check-in coordinates authored by the user are cleared,
- POI and geofence comments on objects created by the user are cleared.

The flow records a privacy-safe deletion audit row in `privacy_deletions` containing only
the deleted user id, requester id, status, timestamps, and aggregate outcome counts. It does
not store email addresses, display names, token values, comments, coordinates, or raw
failure payloads.

Self-service deletion is exposed from the profile page behind an explicit confirmation
form. Cancellation is a no-op. Successful deletion signs the browser session out.

## Consequences

- Event, membership, map, activity, and media history keep referential integrity.
- Deleted users cannot authenticate with prior credentials or session tokens.
- The deleted user id remains an internal pseudonymous identifier for historical joins and
  auditability.
- Free-form historical content outside known sensitive fields may still exist as event or
  map content and is retained as collaborative history.
