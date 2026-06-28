# Tribal knowledge: flecs observability (REST / Explorer / stats) — R5

> Status: **desktop IMPLEMENTED + verified** (R5). Web (R5a) follows in the web
> phase. `world.enable_rest` / `world.enable_stats` in `flecs_bindings.c` + `flecs.rb`.

## At a glance
- **What:** surface flecs's built-in remote API so a human/agent gets a full ECS
  view — entities, components, queries, per-system timing — with **zero UI code on
  our side** (the hosted Flecs Explorer connects remotely).
- **Key files:** `mrbgems/flecs/src/flecs_bindings.c` (add `_enable_rest`/
  `_enable_stats`); sugar `mrbgems/flecs/mrblib/flecs.rb` (`enable_rest`,
  `enable_stats`). Amalgamation already built **with** `FLECS_REST`/HTTP/STATS.
- **Cross-refs:** `flecs-binding.md`, `agent-bridge.md` (web ships REST JSON over the
  bridge), roadmap R5/R5a; principle P5 (observe).

## Desktop mechanism (the whole thing)
```c
FlecsRestImport(world);                               // register REST module
ecs_set(world, EcsWorld, EcsRest, {.port = port});    // -> starts HTTP server
FlecsStatsImport(world);                              // per-system timing/world stats
```
The REST HTTP server runs on `:27750` (flecs manages its own thread); it's serviced
during `world.progress`, which the game already calls each frame. Then point the
**hosted Explorer** at it remotely — no local UI:
`https://www.flecs.dev/explorer/?host=localhost:27750`.
Quick check without a browser: `curl http://localhost:27750/world` (or
`/entity/<name>`) returns JSON.

## Ruby API (planned)
```ruby
world.enable_rest(27750)   # default ECS_REST_DEFAULT_PORT
world.enable_stats         # FLECS_STATS for per-system timing
```
Gate behind dev/JAMSTACK_BRIDGE in game code (it opens a local port — P7).

## Web (R5a) — flecs already did most of it
`ecs_http` can't bind a listening socket in the browser, BUT flecs ships, under
`ECS_TARGET_EM`, an `EMSCRIPTEN_KEEPALIVE char* flecs_explorer_request(method, req,
body)` that runs `ecs_http_server_request` against a socketless
`flecs_wasm_rest_server` (a non-static global). Plan for the web phase:
- init it once: `extern ecs_http_server_t *flecs_wasm_rest_server;
  flecs_wasm_rest_server = ecs_rest_server_init(world, NULL);`
- `flecs_explorer_request` is already exported — call it from JS / the bridge and
  ship the JSON over the agent channel; feed `.live/state.json`.
This is the R5a spike's happy path: the request handler is reachable **without** the
socket server thread.

## Acceptance
Desktop: `curl :27750/world` returns JSON and the hosted Explorer shows the live
world; per-system timing visible with `enable_stats`. (Web: covered in R5a.)

## Scar tissue (verified desktop)
- **Works as a 3-liner:** `FlecsRestImport(w)` + `ecs_set(w, EcsWorld, EcsRest,
  {.port})` + `FlecsStatsImport(w)`. No `ECS_IMPORT` macro needed — call the import
  functions directly (avoids a local-var declaration). `ecs_id(EcsRest)` is a fixed
  compile-time id, but you still must import the module so its system/observers run.
- **Verified endpoints** (game looping `progress`, `curl`/urllib on :27750):
  `/world` → 200; `/entity/player?values=true` →
  `{"components":{"Position":{"x":1,"y":2},"Velocity":{...}}}`;
  `/query?expr=Position&values=true` → all matches with values. These are exactly
  what the hosted Explorer drives (`flecs.dev/explorer?host=localhost:27750`).
- **Threading:** the REST HTTP server runs on flecs's own thread (accepts
  connections), but requests are *processed* during `world.progress` — so the game
  must keep ticking for responses (it does, each frame).
- **Gotcha (not REST):** the **base** `world.system(with: [...])` expects component
  **ids/objects** — it does `.to_i`, so string names silently become `0` and the
  system matches nothing. Use `Flecs::Hot.define_system` (resolves names via lookup)
  or pass `Component` objects.
- **In-process REST requests (`rest_request`):** `world.rest_request("GET", "/world")`
  calls `ecs_http_server_request` on the `fl_rest_server` handle (set by
  `enable_rest`). No socket needed — works on desktop AND web identically. This is
  what `bin/snapshot` and `bin/query` use to dump ECS state JSON through the `.live/`
  mount. On desktop, `enable_rest` creates TWO server objects: one with a port (HTTP
  listener for the hosted Explorer) and one socketless (for in-process requests).
  Both share the same world. On web, only the socketless one exists (shared with
  `flecs_wasm_rest_server` for the JS C export). Key endpoints: `/world` (full world
  state incl. entities + components), `/query?expr=<ComponentName>&values=true`
  (matching entities with component values), `/entity/::<name>?values=true` (single
  entity — note the `::` scope separator; may not find entities created without a
  scope path — use `/query` as the reliable fallback).
