# ADR-0002: Geospatial Data Storage — PostGIS

## Status
Accepted

## Context
The application stores and queries geospatial data: point-of-interest locations (points),
geofences (polygons/circles), and live user positions (points). We need efficient spatial
queries such as "is this user inside a geofence?" and "find all POIs within N metres".

## Decision
Use **PostGIS** as the geospatial extension on PostgreSQL.

- Enable via migration: `execute "CREATE EXTENSION IF NOT EXISTS postgis"`
- Use the **`geo_postgis`** Hex package for Ecto/Ash type integration (`Geo.PostGIS.Geometry`).
- Geometry types used:
  - `POINT(lng lat)` — POI locations, user positions
  - `POLYGON` / `MULTIPOLYGON` — geofence boundaries
  - All geometries stored in **SRID 4326** (WGS84, standard GPS coordinate system).
- Spatial index: add `GIST` index on all geometry columns.
- Key queries:
  - `ST_Within(point, polygon)` — geofence membership check (used for entry/exit detection)
  - `ST_DWithin(a, b, metres)` — proximity search
  - `ST_AsGeoJSON(geom)` — serialize to GeoJSON for MapLibre; in Elixir code use `Geo.JSON.encode!/1`

### Geofence entry/exit detection
On each location update from a user, the server checks all public geofences for the event
using `ST_Within`. By comparing the user's *current* geofence membership set against their
*previous* membership set (stored in Presence metadata), transitions are detected:

- **Entered** (was outside, now inside) → insert `Activity.Entry` with action `:entered_geofence`,
  broadcast toast to all members: *"Carlos entered Base Camp"*
- **Exited** (was inside, now outside) → insert `Activity.Entry` with action `:exited_geofence`,
  broadcast: *"Carlos left Base Camp"*

Without transition tracking, every position tick would re-fire the notification. The previous
membership set is stored as part of the Presence metadata for the user (see ADR-0007).

### Geometry types in Ash/Ecto
- The Elixir struct types from `geo` are `%Geo.Point{}`, `%Geo.Polygon{}`, etc.
- The Ecto/Ash column type is `:geometry` provided by `geo_postgis`.
- In Ash resource attributes, declare: `attribute :location, :geometry` and configure
  `geo_postgis` as a custom type extension on the `AshPostgres` data layer.

## Consequences
- **Positive:** Industry-standard spatial database. All spatial operations run in the DB, not
  application code. GeoJSON output integrates directly with MapLibre's data sources.
- **Negative:** PostGIS must be installed on the PostgreSQL instance (`apt install postgresql-*-postgis-*`
  on Linux, or included by default in most managed services). Adds one migration step to dev setup.
