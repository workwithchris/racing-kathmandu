# Racing — Godot 4 agent guide

## Run

```bash
godot --path "/Users/apple/Desktop/untitled folder/racing"
godot --headless --quit-after 120 --path .          # headless sanity
godot --headless --editor --quit-after 300 --path . # reimport assets
```

macOS: no `timeout` command — use `--quit-after <frames>`.

## Scenes

| Scene | What | Entry |
|---|---|---|
| `scenes/kathmandu.tscn` | Real Kathmandu city (main game) | `project.godot` sets this as main |
| `scenes/main.tscn` | Procedural curved test track via `track_builder.gd` | Separate, not the default |
| `scenes/car.tscn` | Shared `VehicleBody3D` car | Used by both |
| `scenes/npc.tscn` | Capsule pedestrian used by `kathmandu_map.gd` | Spawned along road curbs |

README is stale — it says `main.tscn` is the main scene. It's not. Trust `project.godot`.

## Gotchas

1. **engine_force sign inverted**: `VehicleBody3D` positive `engine_force` pushes +Z (backward). `car.gd` uses **negative** values to accelerate nose-first (−Z). All spawn code orients car's −Z along travel direction.

2. **Road ribbons vanish**: flat ground quads face down in top-down view. Road/curb/marking materials must set `cull_mode = CULL_DISABLED` (already done — don't remove).

3. **Terrain height sampling**: road/building draping uses `_height_at()` which matches the terrain mesh triangle split exactly. If you change the terrain mesh, update `_height_at` too.

## Data generation (tools/)

Run in order from `tools/` dir. Bounding box must match across all 3:

```bash
python3 tools/fetch_map.py     # roads + buildings + SRTM elevation → data/kathmandu.json
python3 tools/fetch_trees.py   # trees + parks → merged into kathmandu.json
python3 tools/fetch_places.py  # named POIs → data/places.json
```

Current box: `SOUTH,WEST,NORTH,EAST = 27.6940, 85.2980, 27.7260, 85.3340`

Overpass mirrors + retries built in; the map fetch is slow (elevation API calls).

## What exists

- Real Kathmandu city from OSM: 2281 roads w/ lane markings + curbs, 46069 extruded buildings w/ window texture, 6289 tree billboards, 251 park green patches
- Place search (`navigation.gd`) — 5000 POIs, straight-line HUD arrow + beacon (no routing)
- Minimap (`minimap.gd`) — SubViewport orthographic, north-up, rotating car marker
- Car auto-pauses when typing in search box (`LineEdit` focus check in `_physics_process`)
- Pedestrian NPCs (`npc.gd` / `npc.tscn`) — spawned on wider-road curbs, walk back and forth along sidewalks

## Limitations (don't expect working)

- No turn-by-turn routing (just as-the-crow-flies)
- No landmark models (Dharahara, Durbar Square, Boudhanath)
- No brick/photo textures on buildings
- No timed challenges or game-like structure beyond free drive

## Debugging trick

Add a temp Node script that calls `Input.action_press("accelerate")` and saves a PNG: `get_viewport().get_texture().get_image().save_png("debug.png")`. Run headless once, inspect PNG.

## Key files

- `progress.md` — authoritative handoff doc (more current than README)
- `data/kathmandu.json` (~12 MB) — do not hand-edit (machine-generated)
- `data/places.json` — 5000 searchable POIs
- `scripts/kathmandu_map.gd` — builds terrain, roads, buildings, trees from JSON; also spawns NPCs
- `scripts/car.gd` — input → engine_force (note sign!), brake, steering
- `scripts/npc.gd` — pedestrian back-and-forth sidewalk walker
- `scripts/navigation.gd` — place search + HUD direction arrow (straight-line, not routed)
- `scripts/minimap.gd` — top-down ortho SubViewport, north-up

## No tests / no lint / no CI

This is a game project. No test framework, no linter, no typechecker, no CI config. Verification is manual (run the scene and look).

## Style

- GDScript, `snake_case` for functions/vars, `PascalCase` for classes
- `@export var` for inspector-tweakable values
- `_ready()` / `_process(delta)` / `_physics_process(delta)` lifecycle
- SurfaceTool + StandardMaterial3D for procedural meshes
