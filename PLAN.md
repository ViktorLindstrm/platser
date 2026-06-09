# Event Map Search Plan

## Intent

- Add event-map search that combines current event POIs with an external geocoder.
- Keep search results clearly labeled by source so users can distinguish app data from external map data.
- Let selected external results create a temporary map pin with a "Create POI" action that enters the existing POI creation flow.

## Architecture

- Follow ADR-0032 for the search result contract, provider choice, search semantics, temporary pin lifecycle, and testing approach.
- Add a non-persistent search boundary under `Platser.Map.Search`.
- Use the existing `Platser.Map.Poi` Ash resource for internal results; do not add persistence for external results or temporary pins.
- Use server-side external geocoding through `Req`; never call the provider directly from the browser.
- Keep POI creation authoritative in the current `MapLive` POI state machine from ADR-0013.

## Task Sequence

1. Task #76: implement internal map search.
   - Search only POIs visible to the current actor in the current event.
   - Normalize results into the ADR-0032 result shape.
   - Add security-focused tests proving another event's POIs are not returned.

2. Task #77: implement external map geocoder.
   - Use configurable Nominatim-compatible HTTP endpoint through `Req`.
   - Enforce explicit-submit search, provider timeouts, response normalization, error handling, and deterministic HTTP stubs in tests.
   - Preserve provider limits: no autocomplete against the public service and no more than one public-provider request per second for the application.

3. Task #78: build map search UI.
   - Add a top map search control that can collapse/minimize on mobile and desktop.
   - Use unique DOM IDs for the form, input, collapse button, result list, no-results state, and result rows.
   - Show source/type labels for every result and surface provider errors through flash.

4. Task #79: add temporary search result pin.
   - Selecting a result focuses the map and replaces any previous temporary pin.
   - Render the temporary pin as a distinct classic teardrop marker, separate from persisted POI GeoJSON.
   - Add a "Create POI" action near the temporary pin.
   - Keep the temporary pin lifecycle separate from the search input/results lifecycle.

5. Task #80: connect temporary pin to POI creation.
   - The temporary pin action enters the existing POI creation flow with `poi_step: :editing` and `poi_location` set to the selected point.
   - Pre-fill the POI name from the selected result title when available, but let existing validations and permissions remain authoritative.
   - Clear the temporary pin once creation starts, is cancelled, or completes.

6. Task #82: decouple temporary pin clearing from search UI clearing.
   - Clearing the search input clears only the input, result list, and no-results state.
   - Collapsing/minimizing search frees viewport space without removing the current temporary pin.
   - The temporary pin exposes its own explicit clear control and keeps "Create POI" as the handoff into the existing POI creation flow.
   - Selecting a result from a later search replaces the current temporary pin instead of accumulating pins.

7. Task #81: review and harden.
   - Review implementation against ADR-0032 and this plan.
   - Run `mix precommit` and fix pending issues.
   - Use browser interaction for the LiveView flow where useful.

## Notes For Implementation

- Do not introduce a second "quick create" endpoint for search results.
- Do not expose external provider raw payloads to templates; normalize first.
- Coordinate order at external boundaries is provider-specific, but the app stores points as `%Geo.Point{coordinates: {lng, lat}, srid: 4326}`.
- Category search means app POI categories internally and provider-supported OSM layers/types externally; unsupported category mappings should degrade to text search rather than pretending to be exhaustive.
- Nearby search should be biased by event bounds when available and by current map viewport when the UI supplies it.
