# Map User Management Plan

## Task #96 ADR and Implementation Plan

- Status: completed.
- Reviewed AGENTS.md and the role-sensitive ADRs: ADR-0004, ADR-0005, ADR-0011,
  ADR-0014, ADR-0019, ADR-0024, ADR-0026, ADR-0027, ADR-0030, ADR-0033, plus the
  current membership, event, map, activity, dashboard, superuser, and tests
  surfaces.
- Added ADR-0042 to separate site-wide Admin/superuser capabilities from
  event-scoped map manager capabilities.
- Canonical membership roles after migration:
  `:full_manager`, `:content_manager`, and `:participant`.
- Backward compatibility:
  existing `:admin` memberships migrate to `:full_manager`; existing `:member`
  memberships migrate to `:participant`. Legacy `:admin` never maps to
  `Accounts.User.superuser`.
- User-facing labels:
  site-wide `superuser` is "Admin"; event-scoped `:full_manager` is
  "Map manager"; `:content_manager` is "Contributor manager"; `:participant` is
  "Member".
- Audit policy:
  permission and membership-management changes are manager-only audit rows, not
  public `Activity.Entry` rows and not `event:{id}:activity` broadcasts.
- Operator support policy:
  no general superuser support access to private map data is accepted. Any future
  support access requires a new ADR/amendment with narrow scope and audit.

## Staged Implementation Sequence

### Task #97 Migration Implementation Notes

- Status: implemented.
- Added typed helpers for map-scoped roles/capabilities and participation settings:
  `Platser.Events.MapAccess` and `Platser.Events.ParticipationSettings`.
- Migration `20260613143918_migrate_membership_roles_and_participation_settings`
  backfills legacy memberships:
  `admin -> full_manager`, `member -> participant`.
- New membership writes use `:full_manager` for event creators and `:participant`
  for invite joins. Legacy `:admin` and `:member` remain readable through the
  compatibility helper while later policy/UI cleanup lands.
- Added persistent participant settings on `events`:
  `allow_participant_comments`, `allow_participant_check_ins`, and
  `allow_participant_live_location`.
- `allow_public_comments` remains as a write-through compatibility column for
  existing code and exports. Runtime comment checks now use
  `allow_participant_comments`.
- Manager eligibility is registered-user-only: guest memberships cannot be
  promoted to `:full_manager` or `:content_manager`.
- Site-wide `superuser` remains separate and still does not grant event reads,
  private map-item reads, member-management powers, or settings updates.

### Task #98 Capability Policy Implementation Notes

- Status: implemented.
- Ash policies now derive role sets from `Platser.Events.MapAccess` capability
  truth tables instead of spelling direct `:admin`/`:member` assumptions in
  resources.
- `manage_any_map_item` governs private map-item visibility and POI/geofence/
  attachment publish, metadata, and delete moderation.
- `manage_event_settings`, `manage_join_code`, and `manage_members` remain
  full-manager-only and do not include `content_manager` or site-wide
  `superuser`.
- UI role checks that needed compatibility now use `MapAccess` normalization,
  keeping UI checks secondary to Ash action authorization.
- StreamData coverage verifies capability role-list derivation, full-manager
  boundaries for settings/member actions, content-manager map-item moderation,
  participant denial for others' private items, and site Admin separation.

### Task #99 Manager Audit Implementation Notes

- Status: implemented.
- Added `Platser.Events.ManagerAuditEntry` and migration
  `20260613154403_create_manager_audit_entries` for append-only manager audit
  rows.
- Audited transitions are membership removal, permission changes, join-code
  regeneration/invalidation, and participation setting changes.
- Audit writes run from Ash domain action hooks after successful transactions,
  not from LiveView handlers, and do not create or broadcast public
  `Activity.Entry` rows.
- Audit visibility is limited to full map managers through the
  `view_manager_audit` capability; site-wide `superuser` alone sees no audit
  rows.
- DSAR export includes manager audit rows where the subject is actor or target,
  with identifiers, closed action values, safe metadata, and no join-code
  secrets or user-facing PII.

1. Capability vocabulary and compatibility helpers.
   - Add a small boundary/domain module for membership levels and capability
     checks with Elixir 1.20 `@type` closed unions and `@spec` on every function.
   - Support both legacy `:admin`/`:member` and target
     `:full_manager`/`:content_manager`/`:participant` while the migration is
     underway.
   - Add StreamData coverage for capability monotonicity, last-manager guard
     inputs, and legacy role normalization.

2. Membership migration.
   - Generate the migration with `mix ecto.gen.migration`.
   - Backfill `memberships.role`: `admin -> full_manager`, `member -> participant`.
   - Update `Platser.Events.Membership` constraints and code interfaces so new
     writes use only target role names.
   - Keep reads tolerant of legacy atoms until fixtures and historical data are
     fully migrated.

3. Ash policy updates.
   - Replace raw `role == :admin` checks in Event, Membership, POI, Geofence,
     Media.Attachment, search, and boundary helpers with capability predicates.
   - Ensure private item visibility is:
     full manager: any item; content manager: any item; participant: own private
     items only.
   - Ensure member/settings/join-code/permission actions require
     `manage_members`, `manage_event_settings`, `manage_join_code`, or
     `manage_permissions`, all full-manager-only.
   - Add tests proving superuser alone does not grant event membership, private
     map-data visibility, member-list visibility, or map-manager powers.

4. Manager audit surface.
   - Add a manager-only audit resource for membership removals, permission
     changes, join-code changes, and participation setting changes.
   - Do not use `Activity.Entry` for these manager-only events.
   - Retain audit rows with the event record until a future retention ADR says
     otherwise.
   - Add StreamData tests for audit visibility, append-only behavior, and absence
     from the public activity feed.

5. Dashboard and map UI copy.
   - Rename event-scoped "Admin" labels and actions to "Map manager".
   - Rename "Public comments" copy to member/comment participation wording.
   - Keep DOM IDs stable unless a test explicitly changes with the UI.
   - Verify dashboard member management and map inspection behavior with
     LiveView tests and browser checks where UI behavior changes.

6. Restricted participation settings.
   - Preserve the existing `allow_public_comments` behavior initially, but expose
     it as member comment participation.
   - Add any new settings only with Ash policy enforcement and LiveView tests.
   - Defer advanced settings until the role migration and manager audit surface
     are stable.

7. Hardening and quality gate.
   - Re-review ADR-0042 against the implementation and amend it before broad
     rollout if policy behavior changes.
   - Run focused domain, policy, and LiveView tests after each stage.
   - Run `mix compile --warnings-as-errors`.
   - Run `mix precommit` at the final hardening subtask.

## Acceptance Criteria

- No user-facing event-scoped surface calls a map manager "Admin".
- Existing legacy event admins keep equivalent map-manager powers after
  migration.
- Site-wide Admin/superuser status does not imply event membership, private
  event data visibility, member-management access, or map-manager powers.
- Permission and membership-management changes are visible only on the
  manager-only audit surface and never in the public activity feed.
- StreamData property tests cover pure/domain capability logic and web/LiveView
  outcomes for generated role and event-membership combinations.

# Map Search Improvements Plan

## Task #94 Review and Hardening

- Re-read AGENTS.md, ADR-0032, ADR-0039, ADR-0040, and PLAN.md before the final pass.
- Confirm current public Nominatim policy constraints:
  explicit end-user searches only, one request per second for the whole application, identifying
  User-Agent or Referer, visible attribution, runtime switchability, caching where possible, no
  autocomplete, and no systematic grid/category/download queries.
- Review the current implementation against the intended behavior:
  house-number search uses a conservative structured retry, address labels are normalized,
  result volume is explicit and capped at forty, locale/country/bounds relevance is request
  context, successful normalized provider results are cached briefly, and provider limitations
  are treated separately from app bugs.
- Run focused search and map LiveView tests before broader checks.
- Run `mix compile --warnings-as-errors` and `mix precommit` after documentation updates.
- Use `browser_eval` only if the hardening pass changes LiveView behavior; this pass does not
  intentionally change UI behavior.

## Task #93 Richer Provider and POI Coverage Assessment

- Public Nominatim remains the near-term geocoding provider for explicit-submit, low-volume map
  search.
- Do not use public Nominatim for autocomplete, systematic reverse-query grids, complete
  postcode/town lists, or complete POI/category downloads.
- Near-term provider switchability is the existing `PLATSER_GEOCODER_URL` runtime setting for a
  self-hosted or paid Nominatim-compatible endpoint.
- Longer-term capabilities should be selected separately:
  self-hosted/paid Nominatim-compatible service for higher-volume geocoding, dedicated
  autocomplete-capable search such as Photon/Pelias/Meilisearch-backed extracts for typeahead,
  and Overpass/imported OSM extracts or a commercial place provider for bounded category/nearby
  discovery.
- ADR-0041 records the decision to avoid an unused provider abstraction until a second provider is
  selected.

## Task #92 Server-side Map Search Caching

- Add a supervised in-process `Platser.Map.Search.Geocoder.Cache` without a new dependency.
- Cache only successful, normalized `Platser.Map.Search.Result` lists from `search_external/2`.
  Provider errors, malformed responses, and invalid inputs are not cached.
- Build cache keys from the normalized external-search request contract:
  provider identity and URL, response format version, normalized query or coordinate mode,
  reverse lookup flag, limit, bounds/viewbox, bounded flag, locale, country codes, and category.
- Keep raw provider payloads out of templates and out of the cache; normalization remains the
  boundary between Req/Nominatim-compatible payloads and LiveView.
- Use a short default TTL of sixty seconds with a bounded maximum of 256 entries. Expiry is lazy
  on cache access and insertion, and the oldest inserted entries are evicted when the bound is
  exceeded.
- Cache hits happen before provider requests and therefore before the public Nominatim
  one-request-per-second limiter. Misses still use the existing limiter. Structured-address retry
  results are cached as the final normalized response for the complete explicit submit.
- Privacy posture: keys are SHA-256 digests of bounded request context, values are short-lived
  normalized public map-search results, and the cache is process-local/non-persistent.

## Task #92 Options Considered

- Cachex or another dependency: rejected because the feature needs only a small TTL map and the
  project already prefers simplicity over dependency growth.
- Persistent database cache: rejected because query text and location context should not gain a
  durable retention surface for this low-volume public-provider optimization.
- Caching raw provider responses: rejected because ADR-0032 keeps raw provider payloads inside the
  geocoder boundary, while templates and UI should consume controlled result structs only.
- Per-provider-request cache: deferred because the external search boundary can cache the complete
  normalized response, including structured retry behavior, with less leakage and simpler
  invalidation.

## Task #91 Result Volume Controls

- Keep the first map-search page small at five rendered results for mobile ergonomics.
- Add an explicit "More results" action that increases the rendered cap by ten per click, up to
  forty results, matching Nominatim's documented maximum `limit`.
- Preserve explicit-submit semantics: initial search and More results are user-triggered events;
  no autocomplete, keypress provider calls, grid reverse lookups, or systematic area downloads.
- Use one combined ordering across sources: authorized event POIs first, external map results
  second, deduped by normalized result id, then capped for rendering.
- Preserve the selected temporary pin when More results reloads the result list. Selecting a new
  result remains the only way to replace the pin during search exploration.
- Keep the provider endpoint/runtime settings unchanged. Larger limits remain bounded by local
  type validation and Nominatim's public maximum.

## Task #91 Options Considered

- Higher default limit: rejected because it makes the mobile panel too tall by default and spends
  larger provider result budgets before the user asks.
- Progressive More results: selected because it is explicit, discoverable, and still respects the
  public-provider policy.
- Separate internal/external limits: deferred because it complicates result accounting and can
  render more rows than the selected cap.
- No UI change: rejected because hidden relevant provider results remain undiscoverable.

## Intent

- Complete task #90 by improving external search relevance with locale, optional country filters,
  and current viewport/event bounds as Nominatim-compatible request context.
- Complete task #89 by adding a conservative structured-address retry for house-number searches such as `hövägen 7`.
- Complete task #88 by fixing Nominatim `jsonv2` normalization while keeping the ADR-0032 result contract.
- Keep `format=jsonv2`; Nominatim documents it as the same output as JSON except `class` is renamed to `category` and `place_rank` is added.
- Normalize provider fields in `Platser.Map.Search.Geocoder`, so LiveView templates continue to receive only `Platser.Map.Search.Result` structs and never branch on raw provider payloads.

## Normalization Approach

- Read provider category from `category` first and fall back to legacy `class` for compatible providers and older fixtures.
- Treat `type` and `addresstype` as classification signals for address-like results when category/class is missing or ambiguous.
- Classify `house`, `postcode`, `building`, `residential`, and address-like payloads as `:address`.
- Derive labels from the normalized kind and provider type/category: addresses display `Address`, POI-like provider categories display useful type labels such as `Restaurant` or `Camp site`, and unknowns fall back to `Place`.
- Build address text from user-useful address parts in stable order, combining house number/name with road where possible and suppressing metadata fields such as `country_code` and `ISO3166-*`.

## Structured Address Retry

- Run free-form Nominatim search first to preserve existing broad place/POI behavior.
- Retry with structured fields only when the query clearly looks like a street address and the free-form result set is empty or lacks a useful matching address result.
- Never combine `q` with structured fields; structured retries use fields such as `street`, `city`, `country`, and `postalcode`.
- Keep a single structured retry per explicit user submit. Public-provider rate limiting still applies per provider request.
- Merge structured results ahead of weak free-form results and dedupe by normalized result id.
- Preserve event/map `viewbox` bias for both free-form and structured requests.
- When structured address retry has bounds, promote those bounds to `bounded=1`; misleading global address matches are worse than an empty local result.
- If a weak free-form result triggered structured retry and the structured retry is empty, return no external results instead of keeping the weak global matches.

## Non-Goals

- Do not hard-code a Sweden-only country filter.
- Do not implement autocomplete or provider calls on keypress.
- Do not infer the current browser viewport for search bias in this slice; that belongs to the locale/viewport-bias task.
- Do not attempt to parse every international address format.

## Verification Plan

- Add deterministic `Req.Test` cases for JSONv2 house-number payloads and mixed JSON/JSONv2 provider payloads.
- Add deterministic `Req.Test` cases for empty free-form fallback, weak global-result fallback, useful free-form preservation, and viewbox-preserving structured retries.
- Add deterministic `Req.Test` coverage that bounded structured retries suppress weak global address results when no local match exists.
- Add StreamData property coverage for normalized external results: finite WGS84 points, stable provider/source fields, required labels present, and no raw metadata leakage in address text.
- Add StreamData property coverage for structured retry invariants: accepted address-like input never combines `q` with structured fields and keeps bounded field sizes.
- Add StreamData-backed LiveView assertions that generated normalized labels render with stable result DOM IDs and expected source/type badges.
- Run `mix test test/platser/map_search_test.exs`, the relevant MapLive test slice, `mix compile --warnings-as-errors`, and `mix precommit`.

## ADR Review

- ADR-0032 already permits machine-readable Nominatim JSON output and normalized result structs. Because this work keeps `jsonv2` and does not change the result contract, no ADR amendment is planned.

## Task #90 Relevance Policy

- `viewbox` biases Nominatim ranking toward a rectangle; it does not exclude global matches.
  `bounded=1` turns that viewbox into a hard filter and remains reserved for explicitly
  constrained semantics, including structured address retries inside known bounds.
- For normal explicit-submit search, prefer valid current browser viewport bounds submitted with
  the search form. Fall back to explicit event bounds, then object-derived fallback bounds.
- Do not infer `countrycodes` from bounds. Nominatim treats country codes as hard filters, so this
  must come from explicit runtime/event configuration rather than reverse-geocoding or guessing.
- Locale is provider request context. Use a runtime `:geocoder_accept_language` setting when
  configured; otherwise omit `accept-language` and let the provider default.
- Keep Nominatim `layer` and `featureType` out of this slice. They are hard result restrictions
  and need explicit UI semantics before use.
- Invalid viewport bounds from the browser are ignored and fall back to safer event/object bounds.
  Invalid provider options passed to the search boundary return typed errors.

## Task #90 Verification Plan

- Add deterministic `Req.Test` assertions for `accept-language`, `countrycodes`, and viewport
  precedence over event/fallback bounds.
- Add StreamData property coverage for valid bounds serializing as `west,north,east,south`, invalid
  provider bounds being rejected, and LiveView generated viewport submits keeping stable DOM IDs.
- Run focused search and MapLive tests, `mix compile --warnings-as-errors`, and `mix precommit`.

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
