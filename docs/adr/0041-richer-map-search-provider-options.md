# ADR-0041: Richer Map Search Provider Options

## Status

Accepted

## Context

ADR-0032 selected a Nominatim-compatible external geocoder for explicit-submit event map
search. Tasks #88 through #92 improved result normalization, structured address retries,
locale and viewport relevance, explicit result-volume controls, and short-lived server-side
caching.

Those improvements make public Nominatim usable for low-volume MVP search, but they do not
change the provider's product limits:

- Public Nominatim is for directly user-triggered searches under a whole-application traffic
  ceiling of one request per second.
- The app must identify itself with a User-Agent or Referer, display OpenStreetMap attribution,
  be switchable without a software update, and cache repeated requests where possible.
- Public Nominatim must not power autocomplete, systematic reverse-query grids, complete
  postcode/town lists, or complete POI/category downloads.
- Nominatim search returns best matches, not complete category inventories. For complete OSM
  object sets, use an extract or a service built for area/category discovery.
- Nominatim structured search fields must not be combined with `q`.
- Nominatim `limit` cannot exceed 40, `viewbox` biases ranking, and `bounded=1` turns the
  viewbox into a filter.

The product will eventually need four separate capabilities:

- Geocoding: explicit place/address/coordinate lookup from user-entered text.
- POI search: finding named provider POIs relevant to a submitted query.
- Nearby/category discovery: finding complete or near-complete sets of objects in an event area.
- Autocomplete: low-latency suggestions while typing.

## Decision

Keep the current Nominatim-compatible provider as the near-term geocoding provider. Do not add a
new provider adapter or dependency in this hardening pass.

For richer coverage, choose provider paths by capability instead of treating all map search as one
provider problem:

| Capability | Near-term path | Longer-term path |
| ---------- | -------------- | ---------------- |
| Geocoding | Continue explicit-submit Nominatim-compatible `/search` and `/reverse` through `Platser.Map.Search.Result`. | Switch `PLATSER_GEOCODER_URL` to a self-hosted or paid Nominatim-compatible endpoint when volume, SLA, or policy constraints require it. |
| POI search | Continue best-match provider results with modest limits and local event POIs sorted first. | Add a provider adapter behind the normalized result contract only when a specific provider is selected. |
| Nearby/category discovery | Do not use public Nominatim for complete area/category lists. | Import OSM extracts or use a service built for area/category discovery, such as Overpass for carefully bounded operator-approved queries or an indexed extract. |
| Autocomplete | Do not implement autocomplete against the public Nominatim API. | Use a dedicated autocomplete-capable service, such as self-hosted Photon, Pelias, Meilisearch-backed extracts, or a paid provider that explicitly allows autocomplete. |

The normalized `Platser.Map.Search.Result` contract remains the architecture boundary. Future
providers must normalize to that contract before LiveView templates, hooks, or persisted map
flows see the data. Provider-specific raw payloads must stay inside provider adapters and tests.

Do not introduce a provider abstraction before a second provider is selected. The current
geocoder module is already the boundary selected by ADR-0032, and adding an unused abstraction
would make the code harder to reason about without improving switchability. Runtime endpoint
switching remains the supported near-term switch path for Nominatim-compatible providers.

## Options Considered

- Self-hosted Nominatim: best compatibility with the current code and policy posture, but has
  meaningful import, update, disk, and operational cost. Suitable when the app needs higher
  volume or tighter control while keeping geocoding semantics.
- Paid Nominatim-compatible provider: low code change and better SLA, but introduces cost,
  contract terms, possible response-shape differences, and provider lock-in.
- Photon/Pelias/Meilisearch-style search: better suited for autocomplete and text search UX, but
  requires new indexing and adapter work. It should be evaluated when autocomplete becomes a real
  product requirement.
- Overpass or imported OSM extracts: appropriate for bounded category/nearby discovery and
  complete object sets. Public Overpass-style querying still needs careful rate and timeout
  controls; imported extracts provide more control at the cost of operations.
- Commercial geocoding/place APIs: can provide rich POI and autocomplete behavior with SLA, but
  usually introduce proprietary terms, data-licensing constraints, API keys, and stronger lock-in.

## Consequences

- The current implementation remains policy-compatible for public Nominatim because it keeps
  explicit-submit UX, one-request-per-second public-host limiting, runtime endpoint switching,
  bounded result counts, short-lived caching, and no autocomplete/systematic area download path.
- House-number search quality improves inside known bounds, but provider coverage gaps remain
  normal provider limitations rather than app bugs.
- Complete nearby/category discovery and autocomplete stay out of scope until the project selects
  a provider designed and licensed for those capabilities.
- Future provider work should add StreamData tests proving every adapter returns the same
  normalized result invariants and LiveView renders through the same source/type/result DOM
  contract.
