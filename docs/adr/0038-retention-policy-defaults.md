# ADR-0038: Retention Policy Defaults

## Status

Accepted

## Context

Privacy-sensitive collaboration data includes check-in coordinates, activity feed rows,
temporary guest accounts, uploaded media, and DSAR export artifacts. ADR-0026 left guest
cleanup as future work, ADR-0036 defined seven-day DSAR artifact expiry, and ADR-0037
established tombstoning/anonymization instead of physical user deletion when historical
foreign keys must remain valid.

## Decision

Add a default retention boundary in `Platser.Privacy.Retention` and run it from a supervised
periodic worker. The job is idempotent and records each run in `privacy_retention_runs` with
status, cutoffs, aggregate outcome counts, and sanitized failure text for operator review.

Default windows and actions:

| Data class | Window | Action |
|------------|--------|--------|
| Check-ins | 30 days | Preserve the activity row but clear latitude/longitude and replace the message with a neutral retained-check-in message. |
| Activity feed entries except check-ins | 365 days | Delete feed rows; canonical event, membership, POI, and geofence records remain the source of truth. |
| Temporary guest accounts | 30 days | Tombstone stale guests only when all their event memberships are for ended events; revoke tokens and minimize authored sensitive fields. |
| Attachments | 180 days | Delete attachment metadata and remove local disk files. Missing files are treated as already cleaned. |
| DSAR export artifacts | 7 days | Delete expired export rows and remove local JSON artifacts derived from the export id. |

The worker uses existing OTP primitives rather than adding a scheduler dependency. Tests and
other controlled environments may disable the worker with `:retention_worker_enabled?`.

## Consequences

- Location precision and uploaded media do not live indefinitely by default.
- Guest cleanup follows the existing account-deletion tombstone pattern and keeps historical
  foreign keys intact.
- Cleanup can be safely rerun; already anonymized rows, missing files, and previously deleted
  records are no-ops.
- Operator visibility is aggregate-only and avoids storing raw personal content or raw failure
  payloads.
