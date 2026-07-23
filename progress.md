# Racing — progress & handoff notes

A 3D racing game in **Godot 4.7.1** that lets you drive around a model of **real
central Kathmandu** built from OpenStreetMap + SRTM elevation data, search for
real places, and navigate to them.

---

## How to run

```bash
godot --path "/Users/apple/Desktop/untitled folder/racing"
```

Or open the folder in the Godot editor (4.3+) and press **F5**.

- Main scene: `scenes/kathmandu.tscn` (set in `project.godot`).
- Headless sanity check: `godot --headless --quit-after 120 --path .`
- Reimport assets after edits: `godot --headless --editor --quit-after 300 --path .`
- (No `timeout` command on macOS — use Godot's `--quit-after <frames>`.)

**Controls:** `W`/`↑` accelerate · `S`/`↓` brake/reverse · `A`/`D` or `←`/`→` steer ·
`R` reset to start. Click the **search box** (top) to find a place; the car pauses
while a text field is focused.

---

## What works today

- **Car physics** — Godot `VehicleBody3D` with 4 wheels, chase camera, speed HUD.
- **Three scenes:** `kathmandu.tscn` (main), `main.tscn` (a procedural curved test
  track via `track_builder.gd`), `car.tscn` (shared car).
- **Real Kathmandu city** (`kathmandu_map.gd`, built at load from `data/kathmandu.json`):
  - Heightmapped **terrain** from real SRTM elevation (~3.5 km area, 56 m of relief).
  - **Roads** (2281) drawn as dark asphalt with **yellow dashed lane markings** and
    light **curbs/sidewalks**, draped onto the terrain.
  - **Buildings** (46,069) from real footprints, extruded to real heights, with a
    procedural **window texture** (triplanar) and a colourful Kathmandu palette.
  - **Trees** (6,289) — real OSM trees + ones scattered in the 251 real parks —
    drawn as instanced billboards (`MultiMesh`); park **green patches** on the ground.
- **Place search + navigation** (`navigation.gd`, `data/places.json` = 5000 named POIs):
  search box → nearest matches → pick one → a HUD **arrow + distance** and a tall
  glowing **beacon** point you there (straight-line direction, not road routing).
- **Minimap** (`minimap.gd`) — live top-down orthographic view of the real city in
  the bottom-right corner, with a rotating car marker (north-up).

---

## File map

```
project.godot            main scene + input map (WASD/arrows/R)
scenes/
  kathmandu.tscn         the Kathmandu game (main scene)
  car.tscn               VehicleBody3D car
  main.tscn              procedural curved test track
scripts/
  car.gd                 player driving (see NOTE on engine_force sign below)
  chase_camera.gd        smooth follow camera
  main.gd                speed HUD + R-to-reset
  kathmandu_map.gd       builds terrain/roads/buildings/trees from data/kathmandu.json
  navigation.gd          place search + direction arrow + beacon
  minimap.gd             corner minimap (SubViewport + ortho camera)
  track_builder.gd       procedural curved track (used by main.tscn only)
data/
  kathmandu.json         ~12 MB: roads, buildings, terrain grid (do not hand-edit)
  places.json            5000 searchable named places
tools/                   Python scripts to (re)generate the data (see below)
```

## Regenerating / changing the map data

The `tools/*.py` scripts fetch from OpenStreetMap (Overpass) + elevation APIs and
write into `data/`. Edit the bounding box constants at the top to change the area,
then run in order:

```bash
python3 tools/fetch_map.py     # roads + buildings + SRTM elevation -> data/kathmandu.json  (slow: elevation)
python3 tools/fetch_trees.py   # trees + parks, merged into data/kathmandu.json
python3 tools/fetch_places.py  # named POIs -> data/places.json
```

Bounding box is currently `SOUTH,WEST,NORTH,EAST = 27.6940, 85.2980, 27.7260, 85.3340`
(keep the same box in all three scripts). Overpass mirrors + retries are built in.

---

## Two gotchas already solved (don't reintroduce)

1. **Car drives "backwards":** on this `VehicleBody3D`, positive `engine_force`
   pushes toward +Z. `car.gd` therefore uses **negative** engine_force to accelerate
   nose-first (−Z). Spawner code orients the car's −Z along travel direction.
2. **Roads invisible / buried on terrain:** (a) sample terrain height with the SAME
   triangle split the terrain mesh uses (`_height_at`) and subdivide road segments
   (`_ribbon`) so they hug the ground; (b) flat ground ribbons wind face-down, so
   their materials need `cull_mode = CULL_DISABLED` or they vanish from top-down/
   driving views.

Handy debugging trick used throughout: add a temp `Node` script that drives the car
(`Input.action_press("accelerate")`) and saves `get_viewport().get_texture().get_image().save_png(...)`,
run once, then open the PNG to see the result.

---

## Known limitations / good next steps

- **Not yet "turn-by-turn"** — navigation points as-the-crow-flies. Real routing
  needs a road graph (nodes = OSM road vertices, edges = segments) + A*, then draw a
  route polyline and follow it. This is the most impactful next feature.
- **Look vs. real Kathmandu** — palette/haze were tuned, but there are no landmarks
  (Dharahara, Durbar Square temples, Boudhanath), no brick/photo textures, and roofs
  are flat blocks. Adding a few hand-placed landmarks + brick textures would help most.
- **Flat-ish relief** — 56 m is real but gentle; bump `height_scale` on the `Map`
  node (e.g. 2–3) if you want dramatic hills.
- **Could become a game** — a timed A→B challenge fits naturally now (reuse the
  navigation destination + a lap/finish timer).
- Minor: minimap is north-up with a rotating marker; a rotating (car-up) map is a
  small change in `minimap.gd` if preferred.

Last worked on: 2026-07-24.
