# ADR-0000: Application Purpose & Vision — Platser

## Status
Accepted

## Context
Before any technical decisions, it is useful to record what this application is, who it is
for, and what it is explicitly *not*. This document is the canonical reference for product
intent and should be consulted when evaluating scope for new features.

## What is Platser?

**Platser** (Swedish: *places*) is a collaborative, boundary-defined map for small groups
coordinating within a shared location or event.

An **event** is a time-bounded experience — a hiking trip, a festival, a multi-day
expedition, a city trip — that a group of friends or colleagues participates in together.
Platser gives that group a shared map area where one creator defines the boundary and
invited users add, publish, and explore POIs and regions within it.

### Core value proposition
> *"Everyone can see the map. Everyone can contribute to it. The group stays oriented."*

### Primary users
- **Event admin (initiator):** Creates the event, defines and can edit the shared map
  boundary, and invites participants via a share code.
- **Participants (members):** Join via share code, create their own POIs and regions,
  publish them for the group, share their live position, and see what others are sharing
  in real time.

### Core capabilities
1. **Live map** — WebGL vector map, mobile-first, works in the browser.
2. **Boundary** — a shared map area defined by the creator and editable over time.
3. **Points of Interest (POIs)** — rich markers with name, description, category, photos.
   Can be kept private (draft) or published to the group.
4. **Regions** — named polygon areas with a type, such as camp area, meeting zone, or
   restricted area. Can be private or published.
5. **Live positions** — opt-in GPS sharing; see all sharing members as live markers.
6. **Activity feed** — real-time notification stream: *"Alice published a POI"*,
   *"Bob entered Base Camp"*, *"Carlos joined the event"*.
7. **Join codes** — simple 6-char alphanumeric code to invite friends; no email required.

### Design principles
- **Mobile-first** — the primary use case is in the field on a phone.
- **Simple by default** — joining an event and placing a POI must be achievable in under
  60 seconds.
- **Privacy-aware** — location sharing is opt-in; objects default to private draft state.
- **No infrastructure lock-in** — free and open map tiles (PMTiles/OpenStreetMap data),
  self-hostable, no third-party API keys required for core functionality.

## What Platser is NOT
- Not a general social network or public map.
- Not a navigation or routing app.
- Not designed for emergency response or safety-critical use cases.
- Not intended for events with hundreds of participants (MVP targets groups of 2–20).
- Not a native mobile app — it is a Progressive Web App running in the browser.

## Non-goals (MVP)
- Push notifications (requires native app or service worker investment).
- Offline map editing (read-only offline is a future goal).
- Route planning or turn-by-turn directions.
- Event discovery / public listing of events.
- Replay / historical playback of member positions.

## Consequences
All feature and architecture decisions should be evaluated against this purpose. If a
proposed feature does not serve the core use case of a small group sharing a live map
during a time-bounded event, it should be deferred or rejected.
