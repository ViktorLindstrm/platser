# ADR-0022: Map Navigation — Back-to-Dashboard Link

## Status
Accepted

## Context
The map view (`/events/:id/map`) initially had no navigation affordance to return to the dashboard.
The only visible navigation element was a "users" icon linking to `/join/:code` (the event join form),
which was incorrect and confusing for existing event members. This created a "stranded" user experience —
once on the map, members had no obvious way to navigate back to event management or member information.

## Decision
Implement a clear bidirectional navigation pattern between the map and the dashboard:

1. **Back-to-Dashboard Link**: Add a visible "← Dashboard" link in the map header's top-left area
   that navigates to `/events/:id/dashboard` using Phoenix LiveView's `navigate` to avoid a full page reload.

2. **Repurpose Users Icon**: Change the users icon in the map header from linking to `/join/:code`
   (the join form) to navigating to `/events/:id/dashboard` with the tooltip "View members".
   This provides quick access to member information without confusion.

3. **Navigation Pattern**: Both links use the same navigation target (`/events/:id/dashboard`),
   establishing a clear "home" for event context. The dashboard shows member lists, event details,
   and admin controls, making it the natural hub.

## Technical Details
- The navigation is implemented in `lib/platser_web/live/map_live.ex` (render/1).
- Both navigation links use `<.link navigate={~p"/events/#{@event.id}/dashboard"}>` to maintain
  the LiveView session and avoid full page reloads.
- The dashboard link includes both an icon and text ("Dashboard") for clarity.
- The users icon link is tooltip-labeled ("View members") to clarify its purpose.

## Consequences
- **Positive**: Clear navigation prevents users from feeling stranded. Members can quickly access
  the dashboard to see who else is on the event or to manage it (if admin).
- **Positive**: Both affordances lead to the same destination, reducing cognitive load.
- **Positive**: Uses LiveView `navigate`, preserving session state and providing a smooth UX.
- **Negative**: Removes the ability to access the join form directly from the map; users must
  navigate through the events index (`/events`) to invite others. This is acceptable because:
  - Inviting is an admin responsibility, and admins access the dashboard to regenerate codes.
  - The events index still provides the join-by-code form for new users.

## Verification
- Property tests verify:
  - MapLive always renders a navigation link to the dashboard (by URL presence).
  - MapLive never renders a link to `/join/:code`.
- Integration tests verify both navigation links work and lead to the correct destination.
