# ADR-0036: DSAR Account Export

## Status

Accepted

## Context

Users need a self-service data subject access request export that includes account data,
memberships, activity, check-ins, comments, media metadata, and other records linked to
their account. Existing ADRs require user data and media bytes to stay authorization-gated,
and there is no background job dependency in the application.

## Decision

Add a policy-backed `Platser.Privacy.Export` Ash resource for export requests and artifact
status. Users may create and read only their own export records; superusers may read records
for support. Internal status transitions run with authorization disabled.

Exports are generated asynchronously through a supervised `Task.Supervisor` so LiveView
requests only enqueue the work. Artifacts are JSON files written under `priv/dsar_exports/`,
which is not served by `Plug.Static`. Downloads go through a browser controller that:

- loads the export through Ash with the current user as actor,
- requires `status == :completed`,
- rejects expired artifacts,
- derives the artifact path from the export id instead of trusting request path input,
- sends the file with private, no-store cache headers.

The export format is versioned JSON:

- `format_version`
- `generated_at`
- `subject_user_id`
- `retention.expires_at`
- `inventory`, listing every included section and source table
- `data`, containing account profile, auth token metadata without raw token secrets,
  memberships, member events, created POIs, created geofences, authored activity/check-ins,
  and uploaded media metadata.

Manager audit rows introduced by ADR-0042 are included when the subject user is
the audit actor or target user. The export includes identifiers, closed action
values, old/new permission values, safe metadata, and timestamps, but does not
include join-code secrets, email addresses, display names, or raw operator
support payloads.

Authentication token exports include lifecycle metadata (`purpose`, `created_at`,
`updated_at`, `expires_at`, `extra_data`) but exclude raw token/JTI/subject values to avoid
turning a DSAR file into an authentication bearer artifact.

Artifacts expire seven days after request. Expiry is enforced at download time and recorded
on each export row; a future cleanup task can delete expired files using this inventory.

## Consequences

- DSAR requests do not block LiveView request handling.
- Export bytes are protected by the same authenticated browser session boundary as uploaded
  media.
- Local disk artifact storage follows the current local media storage constraint and can be
  replaced by object storage behind the same controller policy boundary later.
- The export inventory becomes an input to deletion/lifecycle work such as task #63.
