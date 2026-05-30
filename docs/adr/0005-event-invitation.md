# ADR-0005: Event Invitation System — Join Codes

## Status
Accepted

## Context
Users need to invite friends to a shared map event without requiring email addresses or
user lookups. The invitation mechanism should be shareable via messaging apps, QR code,
or verbally.

## Decision
Use **short alphanumeric join codes** to invite participants to events.

- Each event has a unique `join_code`: 6 uppercase alphanumeric characters (e.g. `AX7K2P`).
- Generated at event creation using `:crypto.strong_rand_bytes/1` + Base32-like encoding,
  guaranteed unique via DB unique index.
- A user who is logged in visits `/join/:code` and is immediately added as a `:member`.
  - The join flow can be accessed directly via `/join/:code` URL.
  - Users can also submit a join code via a form on the events index (`/events`) page.
- The admin can **regenerate** the join code at any time to revoke future joins without
  removing existing members.
- The join page shows event name and date before confirming, so the user knows what they're
  joining.

### Future extensions (out of scope for MVP)
- Expiring codes (valid until event starts)
- Per-person invite links with pre-assigned role

## Consequences
- **Positive:** Dead simple UX. Shareable via any channel (chat, QR, verbally). No email
  infrastructure needed.
- **Negative:** Anyone with the code can join. Mitigated by code regeneration and the fact
  that events are invite-only by social contract. Not suitable for high-security scenarios.
