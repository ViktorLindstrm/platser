# ADR-0012: Authentication & User Identity — AshAuthentication

## Status
Accepted

## Context
The application requires authenticated users for all map interactions. All participants must
be identifiable (for activity feed attribution, marker labelling, policy enforcement).
We need to decide on the auth strategy, user identity fields, and how authentication
integrates with Phoenix LiveView.

## Decision
Use **AshAuthentication** (already installed) with password-based authentication and no
OAuth providers for the MVP.

### User identity fields
The existing `Platser.Accounts.User` resource is extended with:

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| email | :ci_string | unique, from AshAuthentication password strategy |
| display_name | :string | shown on map markers, activity feed, member lists |
| hashed_password | :string | managed by AshAuthentication |
| is_simulated | :boolean | default false; dev simulator only |

`display_name` is required on registration. It is the canonical human-readable identity
throughout the application — used in activity feed messages, map marker labels, and
member lists.

### Auth routes
AshAuthentication's Phoenix integration (`AshAuthentication.Phoenix`) provides:
- `GET /sign-in` — sign-in form
- `GET /register` — registration form
- `GET /sign-out` — sign-out action

These are mounted via `AshAuthentication.Phoenix.Router.auth_routes_for/2` in the router.

### LiveView session integration
All protected LiveViews use a `live_session` block with:
```elixir
live_session :authenticated,
  on_mount: [{AshAuthentication.LiveView, :live_session_required}] do
  # map, event, and join routes
end
```
The `current_user` assign is available in all protected LiveViews via this hook.

### Required dependencies (not yet in mix.exs)
- `{:ash_postgres, "~> 2.9"}` — PostgreSQL data layer for all Ash resources
- `{:ash_phoenix, "~> 2.0"}` — Ash + Phoenix LiveView form integration
- `{:ash_authentication_phoenix, "~> 2.0"}` — auth routes and LiveView hooks

## Consequences
- **Positive:** AshAuthentication handles token lifecycle, password hashing (bcrypt),
  and session management. `ash_phoenix` provides `AshPhoenix.Form` for LiveView form
  integration across all create/edit flows.
- **Negative:** Password-only auth is sufficient for a friend-group app but will need
  OAuth (Google, GitHub) if the user base grows. Defer to a future ADR.
- **Note:** `ash_postgres` is **required** on every Ash resource as the data layer
  (`data_layer: AshPostgres.DataLayer`). It must be a direct dependency in `mix.exs`.
