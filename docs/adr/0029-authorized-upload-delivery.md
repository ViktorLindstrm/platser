# ADR-0029: Authorized Upload Delivery — Phoenix Controller + Ash Policy Gate

## Status
Accepted

## Context
Uploaded media (POI and geofence photos) was stored in `priv/static/uploads/` and served
publicly by `Plug.Static`. Any URL of the form `/uploads/{owner_id}/{filename}` was
accessible to anyone — unauthenticated or non-members — bypassing all authorization.

The `Media.Attachment` Ash resource already had membership-based Ash policies governing
metadata reads, but the actual file bytes were served before the router was even reached.

This is a P0 security gap: user-uploaded content must only be visible to event members.

## Decision

Replace public static file serving with an authorized controller delivery path:

### 1. Remove `"uploads"` from `static_paths()`
`Plug.Static` no longer matches `/uploads/*`. Any request to that prefix reaches the
Phoenix router.

### 2. Add `read :get_by_path` action on `Media.Attachment`
A singular `get? true` action that filters by the canonical `path` field. The existing
`action_type(:read)` policy (event membership check) applies automatically.

A unique index and Ash identity are added on `path` to ensure non-ambiguous lookup and
efficient querying.

### 3. `PlatserWeb.MediaController` — auth-gate + file streaming
Handles `GET /uploads/*path` inside the `:browser` pipeline (session is loaded).

Flow:
1. Reconstruct the canonical path string from URL segments.
2. Call `Platser.Media.get_attachment_by_path(path, actor: current_user)`.
   - Ash evaluates the membership policy with the actor from the session.
3. On success: derive the safe disk path from `attachment.poi_id`/`attachment.geofence_id`
   and `attachment.stored_filename`. Path-traverse guard (`Path.expand` + prefix check
   against `uploads_root`) ensures the derived path cannot escape the uploads directory.
4. Stream the file via `send_file/5` with appropriate response headers
   (`content-type`, `content-disposition: inline`, `cache-control: private`).
5. On `Ash.Error.Forbidden` → `403 Forbidden`.
6. On any other error (not found, disk missing) → `404 Not Found`.

### Guest users
Temporary guest users (ADR-0026) are valid `Platser.Accounts.User` records stored in the
session. They are passed as the actor and subject to the same membership policies.

### Unauthenticated requests
`current_user` is `nil`; Ash denies with `Ash.Error.Forbidden` → `403`.

### File path safety
The disk path is **always** derived from DB-canonical fields, never from the raw URL:
```
uploads_root = priv/static/uploads/
disk_path = Path.expand(Path.join([uploads_root, owner_id, stored_filename]))
guard: String.starts_with?(disk_path, uploads_root <> "/")
```
This prevents path traversal even if the database were somehow injected with a crafted
`stored_filename`.

## Known inconsistency
The `Media.Attachment` schema does not have a `file_size` attribute despite it being
mentioned in ADR-0009. This is a pre-existing gap not addressed by this ADR.

## Future: signed URLs for S3
When storage migrates to S3 (see ADR-0009 migration path), `MediaController.show/2`
can be updated to issue a short-lived signed URL and redirect, with no route or policy
changes required.

## Consequences
- **Positive:** File bytes are protected by the same membership policy as attachment
  metadata. Unauthenticated and non-member requests return 403/404. Path traversal is
  mitigated at the controller boundary.
- **Positive:** Zero new dependencies. Uses standard Phoenix `send_file/5`.
- **Negative:** Every media request now hits the database for the authorization lookup.
  The unique index on `path` keeps this O(1) per request. A CDN/object-store with signed
  URLs would be the production-grade solution.
- **Negative:** Files stored locally are unsuitable for multi-node deployments (noted in
  ADR-0009). This ADR does not change that constraint.
