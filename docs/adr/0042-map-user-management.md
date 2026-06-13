# ADR-0042: Map User Management and Contributor Permissions

## Status

Accepted

## Context

The current event membership model has two roles: `:admin` and `:member`.
That role name is now ambiguous because ADR-0030 introduced site-wide
`superuser` access for service operators. The product needs richer map-scoped
user management without letting service operators automatically see private map
data, member data, or map-management controls.

This ADR resolves the terminology and policy model before feature code starts.
It amends ADR-0004, ADR-0011, ADR-0024, ADR-0030, and ADR-0033 where they use
"admin" for event-scoped behavior.

## Decision

### Role vocabulary

Use these terms consistently:

| Scope | Canonical name | User-facing label | Notes |
|---|---|---|---|
| Service-wide | `superuser` | Admin | Operator account for platform health, retention, and support tools. |
| Map/event | `full_manager` | Map manager | Event-scoped manager with complete map-management rights. |
| Map/event | `content_manager` | Contributor manager | Event-scoped manager for shared map content, not membership or settings. |
| Map/event | `participant` | Member | Event participant with normal collaboration rights. |

The word **Admin** in user-facing copy means site-wide service administrator or
operator. It must not be used for map/event manager roles after this migration.

Legacy membership `role: :admin` means map/event scope. It migrates to
`role: :full_manager`; it does not grant or imply `Accounts.User.superuser`.
Legacy membership `role: :member` migrates to `role: :participant`.

### Capability model

Policies should be written against named capabilities, not raw role atoms, once
the migration begins.

| Capability | `full_manager` | `content_manager` | `participant` |
|---|---:|---:|---:|
| `read_event` | yes | yes | yes |
| `read_public_map_items` | yes | yes | yes |
| `read_private_map_items` | yes | own items only | own items only |
| `create_map_items` | yes | yes | yes |
| `publish_own_map_items` | yes | yes | yes |
| `manage_any_map_item` | yes | yes | no |
| `manage_event_settings` | yes | no | no |
| `manage_members` | yes | no | no |
| `manage_join_code` | yes | no | no |
| `manage_permissions` | yes | no | no |
| `view_manager_audit` | yes | no | no |

`content_manager` can edit, publish, and delete any map item in the event,
including private map items, because content moderation requires map-content
visibility. It cannot change membership, invite settings, event settings, or
permission levels.

`participant` keeps the current member behavior: can create private drafts,
publish their own items, comment where event settings allow, and see public map
items plus their own private drafts.

### Ownership and last-manager rules

Each event must always have at least one active `full_manager` membership.
Removing or demoting the last `full_manager` is forbidden. A `full_manager` may
transfer stewardship by promoting another member first, then demoting or removing
themselves.

`Events.Event.creator_id` remains historical provenance. Authorization must use
membership capability checks, not `creator_id`, except for display and export
history.

### Restricted participation settings

The existing `allow_public_comments` field becomes the first setting in a
manager-only event participation policy. The eventual shape should be:

- `allow_participant_comments`: boolean, default false.
- `allow_participant_check_ins`: boolean, default true.
- `allow_participant_live_location`: boolean, default true.

The membership migration implementation adds these three persistent settings in
one migration. `allow_public_comments` remains temporarily as a write-through
compatibility column, with runtime comment checks using
`allow_participant_comments`. Later enforcement work must apply
`allow_participant_check_ins` and `allow_participant_live_location` at the
LiveView and Ash boundaries before restricted workflows are considered complete.

### Manager audit log

Permission and membership-management changes are manager-only audit events.
They must not be inserted into the public `Activity.Entry` feed and must not be
broadcast on `event:{id}:activity`.

Create a separate append-only audit surface for manager actions before adding
permission-management UI. The audit record must include:

- event id
- actor user id
- target user id, when applicable
- action as a closed enum
- before and after permission level, when applicable
- privacy-safe message
- inserted timestamp

Initial actions:

- `member_removed`
- `permission_changed`
- `join_code_regenerated`
- `join_code_invalidated`
- `participation_settings_changed`
- `operator_support_accessed`, only if support access is later accepted

Visibility is limited to `full_manager` members of the event. Retention follows
the canonical event record for now: audit rows are retained while the event
exists. Future retention policy may add compaction or export treatment, but that
requires a separate ADR amendment.

Implementation note: manager audit rows are stored in a separate
`manager_audit_entries` table and exposed through `Platser.Events` read actions
that filter to `view_manager_audit` members. Normal clients cannot create audit
rows directly; domain action hooks append rows with authorization disabled only
after the audited transaction commits. DSAR exports include rows where the
subject user is either actor or target, using only identifiers, closed action
values, permission/status values, safe metadata, and timestamps.

### Site-wide Admin and support access

`Accounts.User.superuser` remains a service-operations capability. It grants
access to the operator dashboard, aggregate statistics, retention status, error
buffer, and explicit service-maintenance actions documented in ADR-0030 and
ADR-0038.

Superuser status does not automatically grant:

- event membership
- private map item visibility
- member list visibility for a specific event
- map manager powers
- participation settings access
- manager audit visibility

No general operator support backdoor is accepted in this ADR. If support access
to private event data is later required, it must be added by a new ADR or
amendment that defines a narrow, time-limited capability, manager or user
initiation where possible, unavoidable audit logging, and tests proving ordinary
superuser access is still insufficient.

### Backward compatibility and migration

Migrate in stages:

1. Add compatibility helpers and user-facing copy that treats legacy `:admin` as
   `:full_manager` and legacy `:member` as `:participant`.
2. Add the new membership role values and any capability module in a way that
   can read both legacy and new atoms.
3. Backfill existing rows: `:admin` to `:full_manager`, `:member` to
   `:participant`.
4. Update Ash policies, LiveView checks, tests, and display labels.
5. Remove legacy role values only after all policies and fixtures stop writing
   them.

Database migration code must use `mix ecto.gen.migration`. Ash resource changes
should prefer Igniter-backed generators where available, but direct edits are
acceptable for policy and documentation updates that no generator covers.

## Consequences

- Map management becomes explicit and no longer conflicts with service Admin
  terminology.
- Existing event creators and legacy event admins keep equivalent full manager
  powers after migration.
- Site-wide operators keep aggregate support tooling without gaining silent
  access to private collaboration data.
- Permission changes gain a private audit surface instead of making noisy or
  sensitive public feed entries.
- Tests must cover both pure capability logic and LiveView behavior, including
  the negative case that a superuser who is not a member cannot manage or inspect
  a private event.
