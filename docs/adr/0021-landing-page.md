# ADR-0021: Unauthenticated Landing Page

## Status
Accepted

## Context
The root route (`/`) previously rendered the default Phoenix "Peace of mind from prototype to
production" boilerplate page. Logged-out visitors had no product context and no clear call to
action. The `PageController.home/2` action already redirected authenticated users to `/events`,
so the page was only rendered for unauthenticated visitors.

Platser's core differentiation (collaborative map, join-by-code) must be communicated immediately
to a visitor who arrives from a shared invite link or word of mouth.

## Decision

### Custom full-page layout (no `Layouts.app`)

The landing page renders directly into `root.html.heex`'s `@inner_content` without wrapping in
`Layouts.app`. This allows a full-viewport hero section unconstrained by the `max-w-5xl` main
container used by the authenticated app. The template starts with `<Layouts.flash_group>` (as
required for flash message display) and builds its own navigation header inline.

This is the only controller-rendered template in the app that does not delegate layout to
`Layouts.app`; all other pages (LiveViews) use `Layouts.app`.

### Three-section structure

1. **Nav header** — Platser wordmark, theme toggle, "Sign in" and "Get started" links.
2. **Hero** — headline quoting the core value proposition from ADR-0000, one-sentence subtext,
   two primary CTAs: "Get started" (→ `/register`) and "Sign in" (→ `/sign-in`).
3. **Feature highlights** — three tiles: live map, POIs, join-by-code.
4. **Join section** — form with a 6-character code input that posts to `GET /join?code=ABCDEF`.
5. **Footer** — minimal wordmark.

### Join-by-code form via server redirect

A new `GET /join` route handled by `PageController.join_redirect/2` reads the `code` query
parameter and issues a 302 redirect to `~p"/join/:code"`. This avoids any JavaScript
for the submit interaction and keeps the form action a standard HTML GET form.

**Known limitation:** `/join/:code` is in the `:authenticated` live_session and requires a
logged-in user (`live_user_required`). An unauthenticated visitor who submits the join form will
be redirected to `/sign-in` without the join code being preserved. This is accepted as a
known limitation for the MVP. A future improvement should either:
- Move `/join/:code` to a separate live_session with `:live_user_optional` and handle the
  unauthenticated case in `JoinLive` (redirect to `/register?return_to=/join/:code`), or
- Modify `live_user_required` to include a `return_to` parameter in the sign-in redirect.

## Consequences

- The `/` route now serves as the product landing page for unauthenticated visitors.
- A new `GET /join` route is added to handle the code-redirect flow.
- `PageController` has two public actions: `home/2` and `join_redirect/2`.
- All other authenticated pages continue to use `Layouts.app`.
