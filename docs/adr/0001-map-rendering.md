# ADR-0001: Map Rendering — MapLibre GL JS + PMTiles

## Status
Accepted

## Context
The application requires an interactive, mobile-first map that supports vector tile rendering,
geofence overlays, POI markers, and smooth real-time updates. We evaluated Leaflet.js + OpenStreetMap
raster tiles versus MapLibre GL JS + PMTiles vector tiles.

## Decision
Use **MapLibre GL JS** for map rendering and **PMTiles** as the tile source format.

- **MapLibre GL JS** is a fully open-source WebGL-based map renderer (fork of Mapbox GL JS v1). It supports
  vector tiles, custom styling, smooth animations, bearing/pitch controls, and runs well on mobile.
- **PMTiles** is a single-file archive format for map tiles developed by Protomaps. A PMTiles file can be
  served directly from disk or object storage (S3, Cloudflare R2) using HTTP range requests — no tile
  server process required.
- Regional PMTiles extracts are available free from [protomaps.com/builds](https://protomaps.com/builds).
  For development a country/region extract is sufficient (~1–5 GB).
- MapLibre is integrated into the Phoenix LiveView application via a `phx-hook` JavaScript hook
  (`assets/js/hooks/map_hook.js`). All map state mutations (add/remove/update markers, geofences) are
  driven by the LiveView server pushing events via `push_event/3`.
- **Basemap style:** Use the **`@protomaps/basemaps`** npm package which provides open-source
  MapLibre GL styles designed for Protomaps PMTiles data. The style is imported directly into
  `map_hook.js` — no external style URL or API key required.
- **Initial data load:** On `mount`, the LiveView loads all public POIs and geofences for
  the event from Ash into its assigns, then pushes a `map_init` event to the hook with the
  data serialised as GeoJSON FeatureCollections. This LiveView-assigns approach is appropriate
  for the target group size (2–20 users, handful of POIs). Subsequent changes arrive via
  individual `push_event` calls (`poi_added`, `poi_updated`, `poi_removed`,
  `geofence_added`, etc.).

## Consequences
- **Positive:** WebGL rendering is significantly faster and smoother than Leaflet raster. Vector tiles
  enable custom styling and offline use. No external API key required. PMTiles can be self-hosted
  with zero infrastructure beyond a file.
- **Negative:** Requires downloading a PMTiles file for dev (not auto-bootstrapped). Larger JS bundle
  than Leaflet (~250 KB gzipped vs ~40 KB). Requires a browser with WebGL support (all modern
  browsers and recent iOS/Android satisfy this).
- **Migration path:** PMTiles file can be moved from local disk to S3/R2 by changing a single URL
  config value.
