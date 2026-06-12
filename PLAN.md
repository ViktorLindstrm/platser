# P0 Privacy and Security Hardening Plan

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
- Task #68 is completed.
  - Reviewed ADR-0004, ADR-0009, ADR-0012, ADR-0029, ADR-0033, and ADR-0035 before implementation.
  - Added ADR-0036 for DSAR export format, asynchronous generation, artifact storage, protected download delivery, and seven-day expiry.
  - Added `Platser.Privacy.Export`, `Platser.Privacy.ExportBuilder`, and `Platser.Privacy.ExportStore` to request, build, retain, and authorize account export artifacts.
  - Added a profile-page export request/status/download UI and a protected download controller route.
  - Added StreamData coverage for export completeness/isolation and web request/download states.
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

5. Task #68: implement DSAR export flow. Completed.
   - Created a user-linked data inventory for account profile, auth token metadata, memberships, member events, created map objects and comments, authored activity/check-ins, and uploaded media metadata.
   - Added policy-backed export request records plus asynchronous JSON artifact generation outside static serving.
   - Added a protected `/privacy/exports/:id/download` controller path with owner/superuser authorization, completed-state enforcement, path derivation from export id, and expiry rejection.
   - Added profile UI for requesting an export and viewing status/download availability.
   - Added StreamData property tests for generated histories, cross-user exclusion, request flow, authorization denial, pending/completed/expired download states.
   - Ran `mix compile --warnings-as-errors` and `mix precommit`; both passed.

## Notes For Implementation

- Do not weaken `Event.get_by_join_code`; ADR-0026 deliberately allows public lookup by valid join code for guest onboarding. The brute-force mitigation belongs in rate limiting, not in removing the guest flow.
- Do not serve uploaded media through `Plug.Static` or expose raw file paths as an authorization bypass.
- Avoid global user lookup helpers that return full user records unless their call sites are self/admin-only.
- `sensitive?: true` masks logs and inspect output only; it is not an access-control or response-filtering mechanism.
