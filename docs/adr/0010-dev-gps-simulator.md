# ADR-0010: Development GPS Simulator

## Status
Accepted

## Context
The application's core features (live positions, geofence entry detection, activity feed)
require multiple users sharing GPS positions simultaneously. During development on a laptop
it is impractical to have multiple physical devices. We need a way to simulate multiple
moving users for testing.

## Decision
Build a **dev-only GPS simulator** as a Phoenix LiveView page, available only in the
`:dev` environment (gated via `Application.compile_env`, see Implementation notes).

### Features
- Accessible at `/dev/simulator` (protected by dev-only route pipeline).
- UI allows creating N simulated users (seeded into the dev DB automatically).
- Each simulated user can be assigned a **movement pattern**:
  - `stationary` — stays at a fixed coordinate
  - `linear` — moves in a straight line between two points at configurable speed
  - `random_walk` — random Brownian motion within a bounding box
  - `route` — follows a GeoJSON LineString at configurable speed
- A GenServer (`Platser.Dev.GpsSimulator`) drives the simulation tick (configurable
  interval, default 2 s). On each tick it updates Presence for each simulated user,
  triggering live map updates identically to real users.
- The simulator LiveView shows a mini-map with all simulated users' current positions.
- Simulated users are flagged with `is_simulated: true` on their `User` record so they
  can be visually distinguished on the map (dashed outline marker, different color).

### Implementation notes
- `Mix.env()` is only available at **compile time** and must not be used for runtime
  supervision tree conditionals. Instead, gate the simulator via config:
  ```elixir
  # config/dev.exs
  config :platser, start_gps_simulator: true
  ```
  Then in `Platser.Application`:
  ```elixir
  if Application.compile_env(:platser, :start_gps_simulator, false) do
    children ++ [{Platser.Dev.GpsSimulator, []}]
  end
  ```
- Simulated user sessions are created without real browser connections — positions are
  injected directly into `Phoenix.Presence` by the GenServer.

## Consequences
- **Positive:** Enables realistic multi-user testing on a single laptop. Simulated users
  behave identically to real users from the LiveView's perspective — no test-specific code
  paths in production modules.
- **Negative:** Adds dev-only complexity. Simulator code must be fully isolated behind
  the `start_gps_simulator` compile-env flag. Simulated users (flagged `is_simulated: true`)
  must never appear in production — the flag defaults to `false` in all non-dev configs.
