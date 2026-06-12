# ADR-0035: Upload Image Sanitization and Opaque Media Names

## Status

Accepted

## Context

ADR-0009 stored uploaded photos as `{uuid}_{original_filename}` and persisted the original
client filename in `Media.Attachment.filename`. ADR-0029 later moved delivery behind an
authorization gate, but metadata privacy gaps remained:

- Original client filenames could appear in storage paths, URLs, and response headers.
- Uploaded image bytes could retain EXIF, XMP, text, ICC, or other container metadata.
- Malformed files that passed the extension-level LiveView upload filter could be copied
  directly to disk.

This is a P1 privacy/security hardening item. Authorization remains necessary, but it does
not remove sensitive data embedded in image files or names.

## Decision

Uploaded photos are normalized at ingest before attachment metadata is persisted:

- Storage names are generated as opaque UUID filenames with a validated extension, e.g.
  `{uuid}.jpg`; original client filenames are not used in disk paths, URLs, or response
  headers.
- `Media.Attachment.filename` stores a privacy-safe display name derived from the normalized
  media type, e.g. `image.jpg`.
- JPEG uploads are rewritten without APPn and COM segments, removing EXIF/XMP/comment data.
- PNG uploads keep only critical chunks (`IHDR`, `PLTE`, `IDAT`, `IEND`) and drop ancillary
  metadata chunks such as `eXIf`, `tEXt`, `iTXt`, `zTXt`, `iCCP`, and timestamps.
- WebP uploads keep image/animation payload chunks and drop `EXIF`, `XMP `, and `ICCP`
  chunks. `VP8X` feature flags for EXIF/XMP/ICC are cleared when present.
- Ingest rejects unsupported extensions, unsupported content types, invalid magic bytes,
  malformed containers, and partially corrupted containers before writing the final file.

The authorized delivery architecture from ADR-0029 remains unchanged: `/uploads/*path`
continues to resolve through `PlatserWeb.MediaController` and Ash policies before bytes are
served.

## Consequences

- URLs and storage paths no longer disclose original client filenames.
- Served image bytes no longer carry common sensitive image metadata.
- The first implementation remains dependency-light and local-disk compatible with ADR-0009,
  but it only sanitizes the currently accepted image containers: JPEG, PNG, and WebP.
- Existing rows created before this ADR may still contain original filenames until migrated
  or re-uploaded.
