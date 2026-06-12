# P0/P1 Privacy and Security Hardening Plan

## Intent

- Close the highest-risk privacy and security gaps before broader feature work.
- Ensure uploaded media bytes are authorization-gated, join-code guessing is throttled, and user records/email addresses are not broadly readable by unrelated authenticated users.
- Keep the implementation order narrow so each security boundary has focused tests and review.

## Architecture

- Follow ADR-0029 for authorized upload delivery through `PlatserWeb.MediaController` and `Media.Attachment` Ash policies.
- Follow ADR-0033 for join-flow throttling, user read scoping, and email visibility.
- Follow ADR-0036 for self-service DSAR account exports, artifact retention, and protected download delivery.
- Keep authorization decisions in Ash resources whenever possible; controller plugs may reject traffic before Ash when handling abuse controls such as rate limiting.
- Use existing dependencies and framework primitives. Do not add an HTTP client, broad security framework, or non-StreamData property testing dependency for this P0 scope.

## Current Status

- Task #59 is marked completed on the board, and the implementation appears present:
  - `PlatserWeb.static_paths/0` no longer includes `uploads`.
  - `GET /uploads/*path` routes through `PlatserWeb.MediaController`.
  - `Media.Attachment` has `read :get_by_path` with the existing read policy.
  - `Platser.Media.DiskPath` derives disk paths from canonical attachment fields and has property coverage.
- Task #86 added the request-level regression tests for task #59's routed upload delivery path.
- Task #61 added supervised ETS-backed throttling on `GET /join/:code` and `POST /guest-join/:code`.
- Task #66 is implemented. `Accounts.User` read scope is limited to self, same-event identity, and superusers. Field policies keep `display_name` available for collaboration surfaces while hiding `email` from same-event non-self reads.
- Task #83 quality gate is complete. ADR-0033 matches the final implementation, `mix compile --warnings-as-errors` passes, and `mix precommit` passes.
- Task #60 is completed.
  - Reviewed ADR-0005, ADR-0012, ADR-0024, ADR-0026, and ADR-0033.
  - Added ADR-0034 because expiry and invalidation move join-code lifecycle behavior out of ADR-0005 future work and into accepted architecture.
  - Added event-level lifecycle fields, active-code lookup enforcement, and admin dashboard regeneration/invalidation controls without changing the ADR-0033 rate-limit boundary.
  - Added StreamData property tests for domain lifecycle states and LiveView accepted/rejected outcomes.
  - `mix compile --warnings-as-errors` and `mix precommit` pass.
- Task #65 is completed.
  - Reviewed ADR-0009, ADR-0029, and ADR-0033.
  - Added ADR-0035 for image metadata sanitization and opaque upload filenames.
  - Added `Platser.Media.Upload` to reject malformed/unsupported image containers, strip JPEG/PNG/WebP metadata, and write UUID-only storage names.
  - Tightened `Media.Attachment` create validation so domain writes require privacy-safe display names, supported image content types, opaque stored filenames, and canonical upload paths.
  - Updated LiveView upload handling to skip incomplete rejected entries and avoid canceling completed upload entries after consumption.
  - Focused media, domain, controller, and LiveView property/regression tests pass.
  - `mix compile --warnings-as-errors` and `mix precommit` pass.
- Task #68 is completed.
  - Reviewed ADR-0004, ADR-0009, ADR-0012, ADR-0029, ADR-0033, and ADR-0035 before implementation.
  - Added ADR-0036 for DSAR export format, asynchronous generation, artifact storage, protected download delivery, and seven-day expiry.
  - Added `Platser.Privacy.Export`, `Platser.Privacy.ExportBuilder`, and `Platser.Privacy.ExportStore` to request, build, retain, and authorize account export artifacts.
  - Added a profile-page export request/status/download UI and a protected download controller route.
  - Added StreamData coverage for export completeness/isolation and web request/download states.
  - `mix compile --warnings-as-errors` and `mix precommit` pass.
- Task #63 is completed.
  - Reviewed ADR-0004, ADR-0009, ADR-0012, ADR-0026, ADR-0028, ADR-0029, ADR-0033, ADR-0035, and ADR-0036 before implementation.
  - Added ADR-0037 for account deletion/anonymization policy, token revocation, referential integrity, and privacy-safe audit records.
  - Added self-service profile deletion with user tombstoning, token revocation, sensitive historical-field minimization, and privacy-safe aggregate audit rows.
  - Added StreamData coverage for domain anonymization/referential integrity and profile confirmation/cancellation/post-delete access behavior.
  - `mix compile --warnings-as-errors` and `mix precommit` pass.
- Task #64 is completed.
  - Reviewed ADR-0026, ADR-0029, ADR-0036, and ADR-0037 before implementation.
  - Added ADR-0038 for retention windows, cleanup actions, idempotent scheduling, and aggregate operator visibility.
  - Added `Platser.Privacy.Retention`, `Platser.Privacy.RetentionWorker`, and `Platser.Privacy.RetentionRun` for scheduled cleanup and run logging.
  - Added admin-dashboard visibility for retention status, recent failures, and run outcome details.
  - Added StreamData coverage for generated retention boundaries, idempotent reruns, and generated admin run visibility.
  - Verified the admin retention panel in the browser.
  - `mix compile --warnings-as-errors` and `mix precommit` pass.

## Task Sequence

1. Task #86: add upload delivery authorization regression tests. Completed.
   - Added routed `/uploads/*path` controller coverage in `PlatserWeb.MediaControllerTest`.
   - Covered unauthenticated requests, unrelated authenticated users, authorized event members, missing files, and traversal-shaped URL input.
   - Confirmed #59's authorized delivery implementation with request-level regression tests.

2. Task #61: enforce join flow rate limits. Completed.
   - Added `PlatserWeb.JoinRateLimiter` using a supervised ETS table with IP-plus-normalized-code fixed windows.
   - Applied `PlatserWeb.Plugs.JoinRateLimit` to `GET /join/:code` and `POST /guest-join/:code`.
   - Return the same 429 response for throttled valid and invalid codes.
   - Added focused tests for allowed attempts, throttled attempts, normal guest join flow, and reset-window behavior.

3. Task #66: restrict user read scope and email visibility. Completed.
   - Replace broad authenticated `Accounts.User` reads with self, same-event member, and privileged admin/superuser cases.
   - Keep `display_name` available for member lists, map attribution, activity feeds, and creator labels.
   - Restrict `email` exposure to self and admin/superuser use cases.
   - Add negative tests proving unrelated authenticated users cannot read arbitrary users or emails.
   - Completed in `Accounts.User` policy and field-policy coverage, with focused regression tests in `Platser.UserReadPolicyTest`.

4. Task #83 quality gate. Completed.
   - Reviewed ADR-0029 and ADR-0033 against the final implementation.
   - Ran `mix compile --warnings-as-errors`; it passed.
   - Ran `mix precommit`; it passed after replacing narrow filtered StreamData tick-count generators with direct bounded integer generators in `Platser.GpsSimulatorPropertyTest`.

5. Task #60: harden join-code lifecycle. Completed.
   - Added explicit lifecycle metadata for expiry, rotation, and invalidation.
   - Rejected expired, rotated, and invalidated codes through `Event.get_by_join_code` and `Membership.join`.
   - Added admin-facing invalidation next to existing regeneration controls.
   - Added StreamData property coverage for lifecycle model/domain behavior and join UI outcomes.
   - Verified dashboard invalidation/regeneration and direct rotated-code rejection in the browser.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

6. Task #65: sanitize uploaded images and filenames. Completed.
   - Storage paths and served headers use opaque UUID filenames instead of original client filenames.
   - Uploaded JPEG, PNG, and WebP bytes are rewritten without common EXIF/XMP/text/ICC metadata.
   - Invalid, unsupported, and incomplete upload entries are rejected or skipped without persisting attachment rows.
   - Added StreamData coverage for media metadata generation, Ash attachment metadata validation, sanitizer output, LiveView varied filename uploads, and rejected upload names.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

7. Task #68: implement DSAR export flow. Completed.
   - Created a user-linked data inventory for account profile, auth token metadata, memberships, member events, created map objects and comments, authored activity/check-ins, and uploaded media metadata.
   - Added policy-backed export request records plus asynchronous JSON artifact generation outside static serving.
   - Added a protected `/privacy/exports/:id/download` controller path with owner/superuser authorization, completed-state enforcement, path derivation from export id, and expiry rejection.
   - Added profile UI for requesting an export and viewing status/download availability.
   - Added StreamData property tests for generated histories, cross-user exclusion, request flow, authorization denial, pending/completed/expired download states.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

8. Task #63: implement DSAR delete and anonymize flow. Completed.
   - Reused ADR-0036 inventory as the deletion coverage baseline.
   - Added account tombstoning instead of physical user deletion to preserve event, membership, map, media, and activity foreign keys.
   - Revoked stored auth/session tokens and cleared credentials so deleted accounts cannot authenticate.
   - Recorded privacy-safe aggregate deletion outcomes in `privacy_deletions`.
   - Added profile confirmation UI and StreamData coverage for confirmation, cancellation, post-delete access, and referentially safe anonymization.
   - Verified the profile deletion panel in the browser.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

9. Task #64: implement retention policy defaults. Completed.
   - Check-ins older than 30 days are preserved but stripped of precise latitude/longitude and replaced with a neutral retained message.
   - Non-check-in activity feed rows older than 365 days are deleted; canonical event/map/member records remain authoritative.
   - Guest accounts older than 30 days are tombstoned only when their memberships are all for ended events; guest tokens and sensitive authored content are minimized.
   - Attachments older than 180 days are detached by deleting metadata and removing local files.
   - DSAR export artifacts older than seven days are deleted using id-derived artifact paths.
   - Retention runs are logged in `privacy_retention_runs` with aggregate counts and sanitized failures.
   - Focused StreamData retention domain and admin dashboard visibility tests pass.
   - Verified the admin retention panel in the browser.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

10. Task #84 P1 privacy and compliance hardening umbrella. Completed.
   - Re-reviewed ADR-0004, ADR-0005, ADR-0009, ADR-0012, ADR-0024, ADR-0026, ADR-0028, ADR-0029, ADR-0033, ADR-0034, ADR-0035, ADR-0036, ADR-0037, and ADR-0038 against the completed P1 implementation.
   - Confirmed #60, #65, #68, #63, and #64 each have StreamData property coverage for model/domain behavior and web-visible or LiveView/controller paths.
   - Confirmed dependency-sensitive behavior remains aligned: join-code lifecycle sits behind #61 rate limits, upload sanitization preserves #59 authorized delivery, and deletion/anonymization follows the #68 export inventory.
   - No additional architectural decision was introduced by this umbrella close-out; the implementation decisions are captured by ADR-0034 through ADR-0038.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

## Notes For Implementation

- Do not weaken `Event.get_by_join_code`; ADR-0026 deliberately allows public lookup by valid join code for guest onboarding. The brute-force mitigation belongs in rate limiting, not in removing the guest flow.
- Do not serve uploaded media through `Plug.Static` or expose raw file paths as an authorization bypass.
- Avoid global user lookup helpers that return full user records unless their call sites are self/admin-only.
- `sensitive?: true` masks logs and inspect output only; it is not an access-control or response-filtering mechanism.
