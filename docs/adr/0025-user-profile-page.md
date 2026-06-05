# ADR-0025: User Profile Page — Display Name Management

## Status
Accepted

## Context
After registration, users have no way to change their `display_name` or view their profile information. The `User` resource has a `display_name` field set during registration, but there is no post-registration interface to update it. The `display_name` is a critical field used in activity feeds, member lists, and map markers.

## Decision
Implement a dedicated `/profile` page (LiveView) that allows authenticated users to:
1. View their email address (read-only)
2. Update their display name
3. Navigate from the main layout

### Implementation details

#### Ash Resource Changes
Add a new `:update_profile` action on `Platser.Accounts.User`:
- **Accepts:** `:display_name` only
- **Validation:** `display_name` must be non-empty (enforced via `validate present(:display_name)`)
- **Atomicity:** `require_atomic? false` (non-atomic update permitted)
- **Authorization:** Policy `authorize_if expr(id == ^actor(:id))` — users can only update their own profile

#### LiveView
Create `PlatserWeb.ProfileLive` mounted at `GET /profile`:
- **Lifecycle:** `mount/3` initializes an `AshPhoenix.Form.for_update/4` form from the current user
- **Form handling:**
  - `handle_event("validate", ...)` — real-time validation feedback
  - `handle_event("save", ...)` — submit and persist changes; redirect to `/events` with flash message on success
- **Template:** Clean, focused form with email (read-only) and display_name (editable) fields
- **Navigation:** Add "Profile" link to `PlatserWeb.Layouts.app` header (visible to authenticated users)

#### Layout Update
Update `PlatserWeb.Layouts.app/1`:
- Add `current_user` attribute (optional, default `nil`)
- Add "Profile" navigation link between "My Events" and "Sign out" (shown when `current_scope` is present)

### Form Integration
The form is powered by `AshPhoenix.Form`:
```elixir
form = AshPhoenix.Form.for_update(user, :update_profile, actor: user, as: "user", domain: Accounts)
```
This reuses the `:update_profile` action and its built-in validation.

## Consequences

### Positive
- **Self-service:** Users can now change their display name without admin intervention
- **Consistency:** Reuses `AshPhoenix.Form` pattern established in event creation and editing
- **Security:** Policy-based authorization ensures users can only update their own profile
- **Testable:** `update_profile` action is fully tested with property tests (non-empty name, authorization, persistence)

### Negative
- None identified; the feature is minimal and well-scoped

### Notes
- **No password change:** The profile page handles `display_name` only. Password changes are deferred to a future ADR
- **Email immutable:** Email address is shown read-only to prevent account confusion
- **Atomic transactions:** Update is non-atomic; the operation is simple and does not require transaction guarantees per the AshPostgres defaults
