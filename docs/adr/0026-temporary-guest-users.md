# ADR-0026: Temporary Guest Users

## Status
Accepted

## Context
The `/join/:code` flow previously required a registered account before an invited person could
join a shared map event. This creates friction for first-time visitors who just received an
invite link and do not want to register before seeing what the event looks like.

Task #54 requires an option where invited people can use the app **without registering**, while:
- Requiring a registered account to **create** events
- Preserving guest identity/settings so a guest can later be **upgraded** to a registered account
  without losing memberships or other data

## Decision

### Option B — Auto-provisioned temporary user records

A temporary guest user is a regular `Accounts.User` record with:

| Field | Value for guests |
|-------|-----------------|
| `email` | `guest_<secure_token>@platser.guest` (synthetic, globally unique) |
| `display_name` | provided by the user, or auto-generated as `Guest_<6-char-suffix>` |
| `hashed_password` | `nil` (no password, the JWT token is the credential) |
| `is_guest` | `true` |

Guest users go through the same AshAuthentication token pipeline as registered users:
`AshAuthentication.Jwt.token_for_user/1` is called explicitly in the guest join controller
to generate and persist a JWT token (satisfying `store_all_tokens?` and
`require_token_presence_for_authentication?`), and then injected into `__metadata__.token`
before `store_in_session/2` so the session cookie is valid on the next request.

### Join flow (unauthenticated visitor)

1. Unauthenticated visitor arrives at `/join/:code`.
2. The route lives in a new `live_session :public_join` using `on_mount: [{AshAuthentication.Phoenix.LiveSession, :default}, {PlatserWeb.LiveUserAuth, :live_user_optional}]` so that authenticated users also get their `current_user` correctly loaded.
3. `JoinLive` detects `current_user == nil` and renders a guest join form (display name field).  
   The form posts to `POST /guest-join/:code` via a standard HTML form (not phx-submit).
4. `GuestController.guest_join/2`:
   - Looks up the event using `authorize?: false` (no actor yet).
   - Creates a guest user via `Accounts.create_guest_user(%{display_name: name}, authorize?: false)`.
   - Calls `Events.join_event(join_code, actor: guest_user)`.
   - Generates a JWT with `AshAuthentication.Jwt.token_for_user/1` (stores it in the Token table).
   - Injects the token into `__metadata__` and calls `store_in_session(conn, user_with_token)`.
   - Redirects to the event map.

### Policy changes

- `Events.Event.get_by_join_code` policy changed from `actor_present()` to `always()`.  
  **Rationale:** The join code itself is the shared secret. Exposing event name/dates/description
  to the holder of a valid code is acceptable and consistent with how physical invite links work.
  This allows the guest form to display event info before account creation.
- `Events.Event.create` policy adds `forbid_if expr(actor(:is_guest))`.  
  Guest users are not permitted to create events; they are attendees only.

### Upgrade flow (guest → registered)

1. Guest user sees a persistent upgrade banner in the app layout.
2. Banner links to `/upgrade` (`UpgradeLive` in `live_session :authenticated`).
3. Form: email, password, confirm password.
4. Submits to `POST /upgrade-account` (`GuestController.upgrade_account/2`).
5. Controller calls `Accounts.upgrade_guest_user(user, params)` which runs the
   `:upgrade_to_registered` action:
   - Validates `is_guest == true` (registered users cannot use this action).
   - Accepts `email`, `password`, `password_confirmation`.
   - Validates `password == password_confirmation`.
   - Hashes the password via `AshAuthentication.Strategy.Password.HashPasswordChange`.
   - Sets `is_guest: false`.
6. `add_ons.log_out_everywhere.apply_on_password_change? true` fires, revoking all existing tokens.
7. The controller immediately calls `token_for_user` + `store_in_session` on the updated user,
   establishing a fresh valid session.
8. Redirects to the event map (or home).

Since the user's `id` never changes, all `Membership` records and other associated data remain
intact through the upgrade.

### Guest account lifecycle

Guest accounts that are never upgraded will accumulate over time. This is acceptable for the MVP
but should be addressed by a future cleanup job (e.g., delete guest users older than 30 days with
no active event memberships). A future ADR or enhancement should address this.

## Consequences

- **Positive:**
  - Zero-friction onboarding for invited participants.
  - Full continuity of data through the upgrade path (same user ID).
  - No email infrastructure required for guests.
  - Minimal code surface change; guest users participate in the same domain model.

- **Negative:**
  - `get_by_join_code` is now publicly accessible (no actor required). Any person who finds
    a join code URL can see the event's public metadata. Mitigated by join code secrecy and
    the admin's ability to regenerate codes.
  - Guest accounts accumulate if not cleaned up; future work required.
  - `hashed_password` is `nil` for guests; any code path that assumes a non-nil
    `hashed_password` must be audited.
