# ADR-0033: P0 Privacy and Security Hardening

## Status

Accepted

## Context

Three P0 security gaps must be closed before further feature expansion:

- Uploaded media must not be readable without event-membership authorization.
- Join codes are short shared secrets and must not be brute-forceable through unlimited join page or guest join attempts.
- `Accounts.User` currently allows any authenticated actor to read arbitrary user records, including email addresses, which is broader than the collaboration model requires.

Existing ADRs already define the surrounding constraints:

- ADR-0004 defines events, memberships, users, and the earlier broad `Accounts.User` read policy.
- ADR-0005 and ADR-0026 define invite links, public join-code lookup, and temporary guest users.
- ADR-0028 defines sensitive field masking and explicitly notes that masking is not access control.
- ADR-0029 replaces public upload serving with authorized controller delivery.

## Decision

### Authorized Upload Delivery

Keep ADR-0029 as the upload-delivery architecture. P0 follow-up work should add request-level regression tests against the routed `/uploads/*path` path, covering:

- Unauthenticated requests.
- Authenticated users who are not members of the owning event.
- Authorized event members.
- Missing files after metadata authorization.
- Traversal-shaped URL input.

The implementation must continue to derive disk paths from canonical attachment fields rather than raw URL segments.

### Join Flow Rate Limits

Add application-level throttling to both join-code entry points:

- `GET /join/:code`
- `POST /guest-join/:code`

The throttle key is the remote IP plus normalized join code. The first implementation should use a short fixed window suitable for invite-code guessing protection, with tests controlling time or state deterministically. If a request is throttled, the response must be uniform enough that attackers cannot use throttling behavior to distinguish valid and invalid codes.

The first implementation uses a supervised ETS-backed `PlatserWeb.JoinRateLimiter` with a fixed 5-attempt, 60-second window. The Phoenix router applies a shared plug only to the public join page and guest-join POST route, before the public event lookup or guest account creation runs. Throttled GET and POST attempts return the same 429 response body regardless of whether the submitted code exists.

The public lookup behavior from ADR-0026 remains accepted: a person with a valid join link may see event metadata before account creation. Rate limiting mitigates guessing; it does not remove guest onboarding.

### User Read Scope

Replace the broad `Accounts.User` read policy with scoped reads:

- A user may read themself.
- Event members may read the minimum user identity needed for users who share an event with them.
- Event admins may read user identity needed to administer members in their events.
- Superusers may read users for the admin dashboard.
- AshAuthentication internals remain allowed through the existing authentication bypass.

The project should prefer explicit read actions or calculations for each consumer when the default read action would otherwise expose more fields than required.

### Email Visibility

Email is PII and must not be exposed merely because two users share an event.

Allowed email visibility:

- The user can see their own email.
- Superusers can see email in the admin dashboard.
- Event admins may see member emails only where a concrete administrative UI requires it. If no current UI requires event-admin email display, do not expose it.

Member lists, map attribution, activity feeds, and creator labels should use `display_name`, not email.

## Consequences

- Upload delivery remains policy-backed and gains regression coverage for the actual HTTP path.
- Join-code brute-force attempts are constrained without removing the low-friction invite and guest join flow.
- Some call sites that load `Membership.user`, POI creators, or activity actors may need more explicit read actions or field projections.
- `sensitive?: true` remains useful for logs, but PII protection now also requires authorization and response-shaping.
