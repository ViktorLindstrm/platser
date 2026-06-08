# ADR-0031: Runtime Map Tile Source Configuration

## Status

Accepted

## Context

The map hook supports both PMTiles vector archives and raster tile templates. The LiveViews previously read `:pmtiles_url` with `Application.compile_env/3`, which made the selected map source part of the compiled release.

Docker releases are built before deployment runtime environment variables are available. As a result, a deployed container could keep using the compiled fallback PMTiles sample URL even when operators expected container environment changes to select a different source. If that archive URL returns 404, MapLibre fails to load the base map.

Browsers also require a secure context for geolocation. `http://localhost` is treated as a special development origin, but `http://platser.lan` is not secure and cannot fulfill geolocation requests.

## Decision

Map tile source selection is runtime configuration. Production reads `PLATSER_MAP_URL` in `config/runtime.exs` and stores it in the existing `:platser, :pmtiles_url` application setting.

The default runtime map source is the OpenStreetMap raster tile template:

```text
https://tile.openstreetmap.org/{z}/{x}/{y}.png
```

Deployments that want vector tiles can set `PLATSER_MAP_URL` to a PMTiles URL, for example:

```text
pmtiles://https://example.com/path/to/region.pmtiles
```

The client map hook checks `window.isSecureContext` before calling `navigator.geolocation` and reports a LiveView error instead of triggering a browser geolocation exception on plain HTTP origins.

## Consequences

- Docker deployments can change the map source without rebuilding the image.
- The app no longer depends on the compiled PMTiles sample URL for production map rendering.
- HTTP LAN deployments can still render the map, but location sharing and check-ins require HTTPS or localhost.
- Operators using PMTiles must host a reachable archive URL and configure `PLATSER_MAP_URL` accordingly.
