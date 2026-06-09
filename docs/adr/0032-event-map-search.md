# ADR-0032: Event Map Search

## Status

Accepted

## Context

The event map needs a search control for finding places by name, address, coordinates,
category, and nearby location. Results must include both existing app POIs and an external
geocoding/search source. Users need to distinguish persisted app POIs from external search
results, and selecting an external result should create only a temporary pin until the user
chooses to enter the existing POI creation flow.

Existing decisions constrain the design:

- ADR-0001 keeps map rendering in MapLibre through a LiveView JS hook.
- ADR-0002 stores app geometry as WGS84 SRID 4326 PostGIS geometries.
- ADR-0013 defines the current POI creation state machine and stores `poi_location` as a
  `%Geo.Point{}` socket assign, outside form params.
- ADR-0017 defines event map bounds and the map initialization fallback chain.
- ADR-0031 keeps map tile infrastructure configurable at runtime and aligned with
  OpenStreetMap/PMTiles.

The public Nominatim API is suitable for low-volume, user-triggered geocoding but has strict
operational constraints: public usage must stay under one request per second for the whole
application, provide an identifying User-Agent or Referer, display attribution, cache where
possible, be switchable without a software update, and must not implement client-side
autocomplete against the public API. See:

- https://operations.osmfoundation.org/policies/nominatim/
- https://nominatim.org/release-docs/latest/api/Search/
- https://nominatim.org/release-docs/latest/api/Reverse/
- https://nominatim.org/release-docs/latest/api/Output/

## Decision

Add a non-persistent search boundary under `Platser.Map.Search` and normalize all internal
and external search hits into a shared result shape before they reach LiveView templates or
the map hook.

### External provider

Use a Nominatim-compatible provider for the first external geocoder.

- Default endpoint: `https://nominatim.openstreetmap.org`.
- The endpoint must be runtime-configurable, for example with `PLATSER_GEOCODER_URL`, so
  operators can switch to a self-hosted Nominatim instance or compatible service without
  code changes.
- External calls are server-side only and use the existing `Req` dependency.
- Requests must include an application-identifying User-Agent. Production deployments should
  include a contact email when configured.
- Public Nominatim usage is explicit-submit only. Do not call it for every keypress or build
  autocomplete on top of the public API.
- Public-provider calls must be rate-limited to at most one request per second for the app.
  Prefer short-lived server-side caching for repeated identical normalized queries.

This provider matches the app's open-map posture and requires no proprietary API key for
small-group MVP usage. If usage grows or autocomplete becomes a requirement, switch the
runtime endpoint to a self-hosted or paid Nominatim-compatible service before changing the UI
semantics.

### Shared result shape

Use a typed struct, for example `Platser.Map.Search.Result`, with this conceptual shape:

| Field | Meaning |
|-------|---------|
| `id` | Stable UI/session identifier, namespaced by source. |
| `source` | `:internal` or `:external`. |
| `source_label` | User-facing label such as `"Event POI"` or `"Map"`. |
| `kind` | Closed union such as `:poi`, `:address`, `:place`, `:coordinate`, `:category`. |
| `kind_label` | User-facing type label such as `"POI"`, `"Address"`, or `"Coordinates"`. |
| `title` | Primary result label. |
| `subtitle` | Secondary context: category, address, distance, or provider display name. |
| `location` | `%Geo.Point{coordinates: {lng, lat}, srid: 4326}`. |
| `bounds` | Optional `%{west: float(), south: float(), east: float(), north: float()}`. |
| `category` | App POI category or provider category/type when known. |
| `address` | Normalized address text or `nil`. |
| `distance_m` | Optional distance from the search origin, when the search is nearby-biased. |
| `provider` | `nil` for internal results, `:nominatim` for the default external provider. |

The struct should define `@type` unions for `source`, `kind`, provider, and error reasons.
Do not pass provider raw payloads into templates. Keep raw provider identifiers only as
internal references needed for result IDs or diagnostics.

### Result labels

Every result row must include both source and type:

- Internal POI: source label `"Event POI"` and type label from the app category, for example
  `"Camp"` or `"Hazard"`.
- External result: source label `"Map"` by default and type label derived from
  provider category/type, for example `"Address"`, `"Restaurant"`, `"Natural feature"`, or
  fallback `"Place"`.

The external provider name is intentionally not exposed in the primary result label. Users only
need to distinguish event-created POIs from map-provider findings; provider details remain an
implementation concern.

Internal results should sort before external results when relevance is otherwise similar
because they represent event-specific knowledge.

### Search semantics

Internal search:

- Scope all queries to `event_id` and the current actor through Ash authorization.
- Search visible POIs by normalized name, description, category label, and exact/nearby
  coordinates.
- Category terms match the closed POI category set:
  `:viewpoint`, `:camp`, `:hazard`, `:meeting_point`, `:food`, `:other`.
- Coordinate input may match a nearby POI by distance, but it must never bypass event scope
  or Ash policies.

External search:

- Name and address search use Nominatim `/search` with machine-readable JSON output,
  `addressdetails=1`, a small `limit`, and event/map bounds as a `viewbox` bias when available.
- If the user explicitly asks for nearby results and the UI provides a map viewport or event
  bounds, use `viewbox`; use `bounded=1` only when the user intent is explicitly constrained to
  the event/map area.
- Coordinate input should create a coordinate result immediately and may use `/reverse` to add
  an address label when allowed by rate limits.
- Category search maps app categories to provider text/layer hints conservatively. It is a
  helpful search bias, not a complete POI download. Do not issue systematic area downloads.
- Empty provider responses are normal results, not errors. Network failures, malformed
  responses, and rate-limit responses become typed external-search errors.

Coordinate handling:

- Accept latitude/longitude text only after strict parsing and finite-range validation:
  latitude `-90.0..90.0`, longitude `-180.0..180.0`.
- Normalize all accepted coordinates into `%Geo.Point{coordinates: {lng, lat}, srid: 4326}`.
- Display coordinates with the existing map formatting conventions where possible.

### Temporary pin lifecycle

Selecting a search result sends one normalized result selection to the map hook.

- The hook renders one temporary marker outside the persisted POI GeoJSON source.
- Selecting a different result replaces the previous temporary pin.
- Clearing the search input or collapsing/minimizing the search control clears only search
  input/results viewport state; it does not clear the temporary pin.
- The temporary pin has its own explicit close control. Activating it clears the temporary
  marker and pin-specific action UI without resetting unrelated search/map state.
- Starting POI creation from the temporary pin, cancelling POI creation, creating a POI, or
  leaving the LiveView clears the temporary pin.
- Inspecting or editing a persisted POI clears the temporary pin.
- Temporary pins are never broadcast and never written to Ash resources.
- The map focuses the selected result: use `fitBounds` when result bounds are present,
  otherwise `flyTo` the point with a useful POI-level zoom.

The marker should be visually distinct from persisted POIs while keeping the requested classic
upside-down teardrop shape.

### Create POI handoff

The temporary pin's "Create POI" action enters the existing `MapLive` POI creation flow.

- Set `poi_step` to `:editing`.
- Set `poi_location` to the selected result's normalized `%Geo.Point{}`.
- Pre-fill `poi_name` from the result title when present.
- Keep `poi_category` at the current default unless a safe app category mapping exists.
- Clear `editing_poi_id` and `editing_poi_published`.
- Let the existing `save_poi` flow call `Platser.Map.create_poi/2` and enforce permissions,
  validation, uploads, draft/publish behavior, and broadcasts.

Do not add a separate create endpoint or persist anything when the user only selects a search
result.

## Testing Approach

- Logic tests for query parsing, coordinate validation, result normalization, category mapping,
  result sorting, and provider error normalization.
- Ash/security tests proving internal search respects event membership, POI visibility, owner
  drafts, and admin visibility.
- External provider tests with deterministic HTTP stubs; cover successful responses, empty
  arrays, malformed JSON, timeout/network errors, and 429/rate-limit-style responses.
- LiveView tests using stable DOM IDs for the search form, results, no-results state, error
  flash, collapse toggle, result selection, temporary pin selection event, temporary pin clear
  control, and POI creation handoff.
- StreamData property tests for coordinate parser invariants and normalization invariants:
  accepted coordinates are always finite, in range, and stored as `{lng, lat}` with SRID 4326;
  invalid coordinate-like input never returns a result.
- Use `mix compile --warnings-as-errors` for implementation slices and `mix precommit` during
  final hardening.

## Consequences

- The feature remains aligned with the existing Ash authorization model and POI creation state
  machine.
- External search can ship without proprietary provider lock-in.
- Public Nominatim limitations intentionally shape the UX: explicit-submit search only, no
  public-provider autocomplete, modest limits, attribution, caching, and runtime provider
  switching.
- Temporary pins are local UI state, so search result exploration does not create audit, privacy,
  or broadcast side effects.
- Future providers can be added by implementing the same normalized result contract.
