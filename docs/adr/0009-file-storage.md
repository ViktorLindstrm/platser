# ADR-0009: File Storage — ash_storage

## Status
Accepted

## Context
POIs support rich media: photos uploaded by event participants. We need a file storage
strategy that works for local development and can migrate to cloud storage later.
We want to stay within the Ash ecosystem rather than using Waffle (a non-Ash library).

## Decision
Use **`ash_storage`** (`ash-project/ash_storage`) — the official Ash extension for file
storage and attachments.

- `{:ash_storage, "~> 0.1.0"}` added to `mix.exs`.
- Provides `AshStorage.BlobResource`, `AshStorage.AttachmentResource`, and the `AshStorage`
  host extension, using a `has_one_attached` / `has_many_attached` DSL familiar from Rails
  ActiveStorage.

### Resources
Three Ash resources handle the attachment model:

1. **`Media.Blob`** — stores file metadata (filename, content type, size, service opts).
   Extension: `AshStorage.BlobResource`.
2. **`Media.Attachment`** — links a blob to a `Map.Poi`. Extension: `AshStorage.AttachmentResource`.
3. **`Map.Poi`** — host resource. Declares:
   ```elixir
   storage do
     service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}
     blob_resource Media.Blob
     attachment_resource Media.Attachment
     has_many_attached :photos
   end
   ```

### Services by environment
```elixir
# config/dev.exs and config/test.exs
config :platser, Map.Poi,
  storage: [service: {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}]

# config/test.exs
config :platser, Map.Poi,
  storage: [service: {AshStorage.Service.Test, []}]
```

### Migration path to S3
Override the service in `config/prod.exs`:
```elixir
config :platser, Map.Poi,
  storage: [service: {AshStorage.Service.S3, bucket: "platser-media"}]
```
No DB schema changes required. Requires `req_s3` as an additional dependency when using S3.

### File constraints
- Maximum file size: 10 MB per image.
- Accepted types: `image/jpeg`, `image/png`, `image/webp`.
- Enforced in the attach action via Ash validations.

## Consequences
- **Positive:** Fully native to Ash — blob lifecycle (attach, detach, purge on POI destroy)
  is managed via Ash actions and policies. `AshStorage.Service.Test` provides a clean
  in-memory backend for tests with no disk I/O. Service backend is swappable per environment
  via config with no code changes.
- **Negative:** `ash_storage` is early (v0.1.x) — API may shift. Monitor the changelog.
  Not yet on hex.pm as of the time of writing; install from GitHub if needed:
  `{:ash_storage, github: "ash-project/ash_storage"}`.


## Status
Accepted

## Context
POIs support rich media: photos uploaded by event participants. We need a file storage
strategy that works for local development and can migrate to cloud storage later.
`ash_attachments` does not exist on hex.pm — `waffle` + `waffle_ecto` is the established
Elixir file attachment solution.

## Decision
Use **local disk storage** for the MVP with **`waffle`** + **`waffle_ecto`** for file
attachment handling.

- `waffle` provides the upload pipeline (validation, transformation, storage).
- `waffle_ecto` provides Ecto changeset integration for storing the file path.
- Local storage path: `priv/static/uploads/` (served by Phoenix's static plug in dev).
- Files are organised as: `uploads/{event_id}/{poi_id}/{filename}`.
- Store the relative path in the DB (`path` string field on `Media.Attachment`).
- Maximum file size: 10 MB per image. Accepted types: `image/jpeg`, `image/png`, `image/webp`.

### Waffle integration with Ash
Waffle/waffle_ecto works at the Ecto changeset level. Since Ash uses Ecto under the hood
via `ash_postgres`, waffle_ecto can be wired into an Ash `change` module that wraps the
waffle upload before the Ash action completes.

### Required dependencies
```elixir
{:waffle, "~> 1.1"},
{:waffle_ecto, "~> 0.0.12"}
```

### Migration path to S3
Change the Waffle storage backend config from `Waffle.Storage.Local` to
`Waffle.Storage.S3` (via `ex_aws_s3`) and set the relevant bucket/credential env vars.
No DB schema changes required.

## Consequences
- **Positive:** Zero infrastructure for local dev. Easy to inspect uploaded files.
  Waffle storage backend is swappable via config.
- **Negative:** Files stored in `priv/static/uploads/` must be added to `.gitignore`.
  In production, a volume mount or S3 is required — local disk is not suitable for
  multi-node deployments.
