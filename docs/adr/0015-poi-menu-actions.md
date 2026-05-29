# ADR-0015: POI Menu Actions and UX

## Status

Accepted

## Context

The map currently exposes POI creation through a dedicated bottom-sheet flow, but there is no explicit POI action menu yet. Task #21 asked which actions the POI/menu experience should support, including browse, filter, edit, publish, hide, and delete.

The backend already supports a clear POI lifecycle:

- create a private draft
- publish a private POI to public
- destroy a POI

The LiveView also already treats POI creation as a separate state machine from geofence drawing.

## Decision

Use a small POI context menu that focuses on item-level actions, and keep view-level filtering outside that menu.

### Supported actions

| Action | Availability | Notes |
|--------|--------------|-------|
| Browse | Always for visible POIs | Opens the shared inspection drawer or zooms to the item. |
| Edit | Drafts only, plus owner/admin permissions | Reuses the existing creation sheet. |
| Publish | Drafts only, plus owner/admin permissions | Uses the existing publish action. |
| Delete | Owner/admin only | Uses the existing destroy action. |

### Not included

- **Filter** is a map-level control, not a per-POI action.
- **Hide** is not a separate action in v1; a POI draft is already the hidden state.

## Consequences

- The menu stays small and matches the current backend capabilities.
- Publish/delete permissions stay aligned with Ash policies.
- There is no duplicate UX for "hide" versus "draft".
- Future filter UI can live in the map chrome without overloading the POI menu.
