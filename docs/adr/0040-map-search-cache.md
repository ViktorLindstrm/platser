# ADR-0040: Server-side Map Search Cache

## Status

Accepted

## Context

ADR-0032 selected a Nominatim-compatible external geocoder for explicit-submit event map search.
The public provider policy asks clients to cache where possible and keep request volume low. Task
#91 also added explicit result-volume controls, which means users may repeat the same search while
adjusting UI state. Task #89 added structured-address retries, so one explicit address search can
make more than one provider request.

The app should reduce repeated provider calls without persisting user search text or broadening the
raw provider payload surface.

## Decision

Add a supervised in-process cache at `Platser.Map.Search.Geocoder.Cache`.

- Cache successful normalized external search results only: `{:ok, [Platser.Map.Search.Result.t()]}`.
- Do not cache provider failures, malformed payloads, invalid input, or authorization decisions.
- Use a cache key derived from provider identity and URL, response format version, normalized query
  or coordinate mode, reverse lookup flag, limit, bounds/viewbox, bounded flag, locale,
  countrycodes, and category.
- Store only a SHA-256 digest of the key material.
- Use a sixty-second default TTL and a 256-entry default maximum.
- Expire lazily on access and insert; evict oldest inserted entries when above the entry bound.
- Check the cache before calling Req or waiting on the public-provider rate limiter.
- Keep the cache process-local and non-persistent.

The cache sits at the external search boundary rather than the lower Req request helper. This keeps
raw Nominatim-compatible payloads out of cache storage and lets structured-address retry behavior
be cached as one complete normalized response for the explicit search request.

## Consequences

- Repeated identical searches are faster and avoid consuming public-provider rate-limit budget.
- Cache entries can include user-entered search text in pre-hash key material during key
  construction, but the stored key is only a digest and values are short-lived normalized map
  results.
- Results may be up to the TTL stale. This is acceptable for public map search and avoids
  persistent retention of user searches.
- A node-local cache does not deduplicate requests across multiple runtime nodes. If deployment
  grows to multiple nodes and public-provider pressure remains a concern, operators should use a
  self-hosted/provider-side cache or switch the geocoder endpoint.
