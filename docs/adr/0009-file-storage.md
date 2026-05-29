# ADR-0009: File Storage — Phoenix LiveView Native Uploads

## Status
Amended (supersedes the ash_storage and waffle approaches previously considered)

## Context
POIs support rich media: photos uploaded by event participants. We need a file storage
strategy that works for local development and can migrate to cloud storage later.

Two earlier approaches were evaluated:
1. **`ash_storage`** — The official Ash extension was not yet on Hex.pm and had an
   unstable API at the time of implementation.
2. **`waffle` + `waffle_ecto`** — Waffle is not Ash-native; integrating it requires wrapping
   Ecto changesets in Ash change modules, adding complexity and a non-Ash dependency.

## Decision
Use **Phoenix LiveView's native file upload system** (`allow_upload` / `consume_uploaded_entries`)
with plain `File.cp` for local disk storage.

- No extra Hex dependencies required — Phoenix LiveView ships with first-class upload support.
- Files are stored at `priv/static/uploads/{poi_id}/{uuid}_{original_filename}`.
- Phoenix's static plug serves the files at `/uploads/...` in dev; a CDN or object-store proxy
  serves them in production.
- A custom Ash resource `Media.Attachment` stores file metadata:
  - `filename` (original name), `stored_filename` (server-generated unique name),
    `content_type`, `path` (relative URL), `file_size` (bytes), `poi_id` (FK), `uploader_id` (FK).

### Upload flow
1. LiveView declares `allow_upload(:photos, accept: ~w(.jpg .jpeg .png .webp), max_entries: 5,
   max_file_size: 10_000_000)` in `mount/3`.
2. On form submit, `consume_uploaded_entries/3` streams each file to disk.
3. After the POI is created, one `Media.Attachment` record is inserted per uploaded file.
4. If publishing, the publish action runs after attachments are persisted.

### File constraints
- Maximum file size: 10 MB per image.
- Accepted types: `.jpg`, `.jpeg`, `.png`, `.webp`.
- Enforced by `allow_upload` (client-side validation with server-side enforcement).

### Migration path to S3
Replace the `consume_uploaded_entries` body:
```elixir
# Replace File.cp with an ExAws.S3 put_object call
ExAws.S3.put_object("my-bucket", stored_name, file_binary)
|> ExAws.request!()
```
No DB schema changes required. Path stored in `Media.Attachment.path` becomes the S3 URL.

### .gitignore
`priv/static/uploads/` is added to `.gitignore` to avoid committing user-uploaded content.

## Consequences
- **Positive:** Zero extra dependencies. Native LiveView upload progress tracking and
  client-side validation work out of the box. Ash resource for metadata keeps attachment
  lifecycle (cascade delete when POI is deleted) within the Ash authorization layer.
- **Negative:** Files stored in `priv/static/uploads/` require a volume mount or object-store
  bucket in production — local disk is unsuitable for multi-node deployments. No automatic
  file purge if the LiveView crashes during upload (orphaned files possible; future cleanup job
  needed).
