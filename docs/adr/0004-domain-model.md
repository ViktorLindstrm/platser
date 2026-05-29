# ADR-0004: Core Domain Model

## Status
Accepted

## Context
We need a clear, stable domain model that covers all the collaborative map-sharing features
discussed: events, membership, POIs, geofences, media, and activity.

## Decision

### Required dependencies
The following must be direct dependencies in `mix.exs` (not just transitive):
- `{:ash_postgres, "~> 2.9"}` — PostgreSQL data layer; every resource needs
  `data_layer: AshPostgres.DataLayer`
- `{:ash_phoenix, "~> 2.0"}` — `AshPhoenix.Form` for LiveView form integration
- `{:ash_storage, "~> 0.1.0"}` — file attachments (see ADR-0009)
- `{:geo_postgis, "~> 3.7"}` — PostGIS geometry types for Ecto/Ash
- `{:ash_authentication_phoenix, "~> 2.0"}` — auth routes and LiveView hooks

### Ash Domains
- `Platser.Accounts` — users, authentication (existing)
- `Platser.Events` — events, memberships, join codes
- `Platser.Map` — POIs, geofences, comments
- `Platser.Media` — blobs and attachments (`ash_storage`; see ADR-0009)
- `Platser.Activity` — activity feed entries

### Key Resources

#### `Accounts.User` (extended — see ADR-0012)
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| email | :ci_string | unique, from AshAuthentication |
| display_name | :string | required; shown on map, feed, member list |
| hashed_password | :string | managed by AshAuthentication |
| is_simulated | :boolean | default false; dev simulator only |

#### `Events.Event`
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | PK |
| name | string | |
| description | string | |
| starts_at | utc_datetime | |
| ends_at | utc_datetime | |
| join_code | string | unique, 6-char alphanumeric |
| creator_id | belongs_to User | admin |

#### `Events.Membership`
| Field | Type | Notes |
|-------|------|-------|
| event_id | belongs_to Event | |
| user_id | belongs_to User | |
| role | enum | `:admin`, `:member` |
| joined_at | utc_datetime | |

#### `Map.Poi` (Point of Interest)
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | |
| event_id | belongs_to Event | |
| creator_id | belongs_to User | |
| name | string | |
| description | string | |
| category | enum | `:viewpoint`, `:camp`, `:hazard`, `:meeting_point`, `:food`, `:other` |
| location | :geometry (Geo.Point) | SRID 4326, via geo_postgis |
| visibility | enum | `:public`, `:private` |
| published_at | utc_datetime | nil = draft |

#### `Map.Geofence`
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | |
| event_id | belongs_to Event | |
| creator_id | belongs_to User | |
| name | string | |
| purpose | enum | `:boundary`, `:meeting_zone`, `:restricted`, `:camp_area`, `:other` |
| geometry | :geometry (Geo.Polygon) | SRID 4326, via geo_postgis |
| visibility | enum | `:public`, `:private` |
| color | string | hex color for map rendering |

#### `Map.Comment`
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | |
| poi_id | belongs_to Poi | |
| author_id | belongs_to User | |
| body | string | |
| inserted_at | utc_datetime | |

#### `Media.Attachment`
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | |
| poi_id | belongs_to Poi | |
| uploader_id | belongs_to User | |
| filename | string | original filename |
| content_type | string | image/jpeg, image/png, image/webp |
| path | string | relative path under priv/static/uploads/ |
| inserted_at | utc_datetime | |

#### `Activity.Entry`
| Field | Type | Notes |
|-------|------|-------|
| id | uuid | |
| event_id | belongs_to Event | |
| actor_id | belongs_to User | |
| action | enum | `:poi_published`, `:geofence_published`, `:joined_event`, `:comment_added`, `:entered_geofence`, `:exited_geofence` |
| subject_type | string | "poi" / "geofence" / "comment" |
| subject_id | uuid | |
| message | string | human-readable |
| inserted_at | utc_datetime | |

### Authorization
Ash policies enforce:
- Only event members can read event data
- Users can only edit/delete their own objects
- Admins can delete any object in their event
- Private objects are only visible to their creator (and event admin)

#### `Accounts.User` read policy
Any authenticated actor may read `Accounts.User` records
(`authorize_if actor_present()`). This is required so that event members
can see each other's `display_name` and initials in member lists and on the
map. User records contain no sensitive data beyond `email` and `display_name`
— the `hashed_password` field is marked `sensitive?: true` and is never
returned by read actions.

#### Member list visibility
The `Membership.list_for_event` action is readable by **all event members**
(not just admins). Any participant who is a member of an event may retrieve
the full member list for that event. This is intentional: collaborative
map events benefit from social awareness of who is present. Private
events rely on social contract and join-code secrecy rather than hiding
the participant list from members.

### Invariants
- On `Event` creation, a `Membership` record with `role: :admin` is automatically created
  for the `creator_id`. The `creator_id` field and the `:admin` membership must always
  agree. Prefer querying membership role over `creator_id` for authorization checks.

## Consequences
- Clear domain separation enables independent development of map vs. event management.
- Ash policies centralize authorization logic.
- GeoJSON serialization of PostGIS geometries feeds directly into MapLibre data sources.
