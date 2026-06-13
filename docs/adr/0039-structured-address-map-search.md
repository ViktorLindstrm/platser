# ADR-0039: Structured Address Map Search

## Status

Accepted

## Context

ADR-0032 introduced event map search with Nominatim-compatible free-form provider queries.
Free-form address searches can return globally plausible but locally useless results. For example,
an event map bounded around Stockholm may return `7, Heinätie, Finland` for `hövägen 7` because
Nominatim treats the event `viewbox` as a ranking boost, not a hard filter.

Nominatim supports structured search parameters such as `street`, `city`, `country`, and
`postalcode`, but these must not be combined with the free-form `q` parameter. The app also must
keep public-provider use explicit-submit only and avoid broad autocomplete-style behavior.

## Decision

Add a conservative structured-address retry inside `Platser.Map.Search.Geocoder`.

- Run free-form search first for normal place, POI, and address behavior.
- Parse only obvious address-like queries, such as street plus house number or simple
  comma-separated address components.
- Retry with structured parameters only when free-form results are empty or do not contain a
  useful matching address result.
- Never combine `q` with structured search fields.
- Preserve the existing event/map `viewbox` on both requests.
- When bounds exist, structured retries promote the bounds to `bounded=1`, so address searches
  return local results or no results instead of misleading global matches.
- If a structured retry is triggered and returns no local result, suppress weak free-form matches.

The parser remains intentionally small. It does not try to solve every international address format
or infer a country from user text.

## Consequences

- Users searching for house-number addresses inside a bounded event map get more relevant local
  results.
- Users no longer see weak global address matches when a bounded structured retry cannot find a
  local address.
- One explicit submit may make a second provider request. Existing public-provider rate limiting
  still applies per request.
- Address searches without event/map bounds can still be global; viewport and locale/country bias
  remain separate follow-up work.
