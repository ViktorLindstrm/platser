# ADR-0015: POI Menu Actions and UX

## Status

Amended (2025 — extended to support metadata editing of published items)

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
| Edit | All statuses, owner/admin only | Reuses the existing creation sheet. For published items only name/description (POIs) or name/color (geofences) are editable. |
| Publish | Drafts only, plus owner/admin permissions | Uses the existing publish action. |
| Delete | Owner/admin only | Uses the existing destroy action. |

### Structural vs. metadata changes

Changes are split into two categories:

- **Structural** (location, category, geometry, purpose) — restricted to draft (`:private`) items via the existing `update` Ash action which validates `attribute_equals(:visibility, :private)`.
- **Metadata** (name, description for POIs; name, color for geofences) — allowed on any visibility status via a dedicated `update_metadata` Ash action with no visibility restriction.

When a user edits a published item, the form hides the structural fields (location picker, category picker for POIs; purpose picker for geofences) and removes the "Save & Publish" button. The standard "Save" button calls `update_metadata` instead of `update`.

### Not included

- **Filter** is a map-level control, not a per-POI action.
- **Hide** is not a separate action in v1; a POI draft is already the hidden state.

## Consequences

- The menu stays small and matches the current backend capabilities.
- Publish/delete permissions stay aligned with Ash policies.
- There is no duplicate UX for "hide" versus "draft".
- Future filter UI can live in the map chrome without overloading the POI menu.
- Owners and admins can fix typos and update descriptions on live (published) items without having to unpublish them first.
