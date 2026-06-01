# ADR-0028: Sensitive Field Masking Across Resources

- **Status**: Accepted
- **Date**: 2026-06-01
- **Related ADRs**: 0007-location-sharing, 0012-authentication, 0026-temporary-guest-users, 0004-domain-model

## Context

Ash 3.0 supports `sensitive?: true` on attributes and action arguments. When set, Ash
redacts the field value in:

- Log output (`Logger` calls made by Ash internals)
- Error messages and inspection output (e.g., `Ash.Error` structs printed to logs)
- `Inspect` protocol output for `Ash.Changeset` and `Ash.Query` structs

Critically, `sensitive?` is **orthogonal to access control** (`public?: false`). It does
not prevent the value from being returned by read actions or used in UI templates — it
only affects observability surfaces (logs, errors, inspect). A field can be both
`public?: true` (returned by API) and `sensitive?: true` (masked in logs).

With growing user data (emails, check-in coordinates, join codes, free-text comments),
this project must align with GDPR data minimisation principles for log data and internal
error traces.

## Decision

The following fields and action arguments are marked `sensitive?: true`. All changes
were applied in one batch.

### `Platser.Accounts.User`

| Field | Type | Reason |
|---|---|---|
| `email` | attribute | PII — directly identifies the person |
| `hashed_password` | attribute | Secret — already marked (AshAuthentication convention) |
| `password` / `password_confirmation` arguments | action args | Secret — already marked |

### `Platser.Accounts.Token`

| Field | Type | Reason |
|---|---|---|
| `jti` | attribute | Auth credential — already marked (AshAuthentication convention) |
| `subject` | attribute | Auth identity claim (`user?id=<uuid>`) — auth infrastructure internals |
| `token`, `jti`, `subject` action arguments | action args | Token material — already marked |

### `Platser.Events.Event`

| Field | Type | Reason |
|---|---|---|
| `join_code` | attribute | Secret credential — anyone reading logs could join the event |

### `Platser.Events.Membership`

| Field | Type | Reason |
|---|---|---|
| `join_code` argument on `:join` | action arg | Live credential passed during join flow |

### `Platser.Activity.Entry`

| Field | Type | Reason |
|---|---|---|
| `lat` | attribute | Precise personal location data — GDPR sensitive |
| `lng` | attribute | Precise personal location data — GDPR sensitive |

### `Platser.Map.Poi`

| Field | Type | Reason |
|---|---|---|
| `comment` | attribute | Free-text user content — may contain personal info |

### `Platser.Map.Geofence`

| Field | Type | Reason |
|---|---|---|
| `comment` | attribute | Free-text user content — may contain personal info |

## Fields Explicitly Not Marked

| Field | Resource | Rationale |
|---|---|---|
| `display_name` | `User` | User-chosen public persona, deliberately shown in UI to other members |
| `location` | `Map.Poi` | Coordinates of a place, not the person; intended to be shared with members |
| `geometry` | `Map.Geofence` | Zone definition, not personal location; shared event infrastructure |
| `stored_filename` / `path` | `Media.Attachment` | Storage paths; not PII; no meaningful GDPR sensitivity |
| `is_guest` / `is_simulated` | `User` | Boolean flags; not PII |
| `message` | `Activity.Entry` | System-generated text describing the activity (e.g. "joined the event") |

## GDPR Alignment

- **Data minimisation in logs**: Email, precise GPS coordinates, and auth tokens are the
  highest-risk categories for inadvertent log retention. Masking these fields ensures
  that even if logs are retained longer than the GDPR storage period, the raw PII is
  not present.
- **Join codes as secrets**: While not PII, join codes are access credentials. Their
  exposure in logs could allow an attacker with log access to join private events.
- **Comments**: Free-text fields may contain incidental PII (names, meeting details,
  personal notes). Masking by default is the conservative choice.

## Consequences

- All approved sensitive fields are masked in Ash log/error output.
- No regressions in API responses or LiveView UI — `sensitive?` has no effect on return
  values or access control.
- Future resources and actions that handle email addresses, coordinates, secrets, or
  free-text should default to `sensitive?: true` until explicitly decided otherwise.
