#!/usr/bin/env python3
"""Add pedestrian footpaths (OSM highway=footway/path/steps) to the already-
fetched valley chunk data, without re-fetching roads/buildings/trees.

tools/fetch_valley.py's ROAD_W table never included footway/path/steps, so
those ways were fetched by its `way["highway"]` query but silently dropped
(no matching width) and never marked in seen_ids.json -- meaning they were
never written anywhere and are safe to fetch fresh here.

Same row-by-row, resumable approach as fetch_valley.py, but its own
done-markers/seen-ids namespace so this can't corrupt or collide with the
main fetch's state. Merges into each data/chunks/{cx}_{cz}.json as a new
"footpaths" array; "roads"/"buildings"/etc. are left untouched.
"""
import json, os, sys, time, urllib.request, urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from chunking import CHUNK_SIZE, chunk_of, split_polyline_by_chunk

SOUTH, WEST, NORTH, EAST = 27.61, 85.186, 27.81, 85.446

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
CHUNKS_DIR = os.path.join(DATA_DIR, "chunks")
CACHE_DIR = os.path.join(DATA_DIR, "valley_cache")
SEEN_IDS_PATH = os.path.join(CACHE_DIR, "seen_ids_footpaths.json")

OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
HEADERS = {"User-Agent": "godot-racing-learning-project/1.0 (personal use)"}

# Narrow, pedestrian-only widths -- deliberately much thinner than any
# vehicle road (see fetch_valley.py's ROAD_W) so footpaths read as sidewalks.
FOOTPATH_W = {"footway": 1.6, "path": 1.3, "steps": 1.5}


def overpass(query: str):
    data = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for _attempt in range(3):
        for url in OVERPASS_MIRRORS:
            try:
                req = urllib.request.Request(url, data=data, headers=HEADERS)
                with urllib.request.urlopen(req, timeout=200) as r:
                    return json.load(r)
            except Exception as ex:
                last = ex
                print(f"    mirror {url.split('/')[2]} failed ({ex}); trying next...", file=sys.stderr)
                time.sleep(3)
    raise last


def load_json(path, default):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return default


def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def merge_chunk_file(path: str, footpaths: list) -> None:
    existing = load_json(path, None)
    if existing is None:
        # No roads/buildings ever landed in this cell -- still worth a file
        # for a footpath-only chunk (e.g. a park path far from any street).
        existing = {"roads": [], "buildings": [], "trees": [], "greens": [], "footpaths": []}
    existing.setdefault("footpaths", [])
    existing["footpaths"].extend(footpaths)
    save_json(path, existing)


def fetch_row(cz: int, project, seen_ids: dict) -> None:
    z_top = cz * CHUNK_SIZE
    z_bot = (cz + 1) * CHUNK_SIZE
    lat0 = (SOUTH + NORTH) / 2.0
    m_lat = 111320.0
    row_north = lat0 - z_top / m_lat
    row_south = lat0 - z_bot / m_lat
    pad = 0.0015
    row_north = min(NORTH, row_north + pad)
    row_south = max(SOUTH, row_south - pad)

    bbox = f"({row_south},{WEST},{row_north},{EAST})"

    print(f"  row cz={cz}: fetching footpaths...", file=sys.stderr)
    raw = overpass(
        '[out:json][timeout:200];(way["highway"~"^(footway|path|steps)$"]'
        f"{bbox};);(._;>;);out;"
    )

    nodes = {e["id"]: (e["lat"], e["lon"]) for e in raw["elements"] if e["type"] == "node"}

    by_chunk: dict = {}
    count = 0
    for e in raw["elements"]:
        if e["type"] != "way":
            continue
        key = f"way/{e['id']}"
        if key in seen_ids:
            continue
        tags = e.get("tags", {})
        highway = tags.get("highway")
        w = FOOTPATH_W.get(highway)
        if w is None:
            continue
        # Indoor/private-access sidewalks clutter the street-level map with
        # paths a driving/walking player will never sensibly reach.
        if tags.get("indoor") == "yes" or tags.get("access") in ("private", "no"):
            continue
        pts = [project(*nodes[n]) for n in e["nodes"] if n in nodes]
        if len(pts) < 2:
            continue
        seen_ids[key] = True
        count += 1
        entry = {"w": w, "steps": highway == "steps"}
        for coord, run_pts in split_polyline_by_chunk(pts):
            by_chunk.setdefault(coord, []).append({**entry, "p": run_pts})

    os.makedirs(CHUNKS_DIR, exist_ok=True)
    for coord, footpaths in by_chunk.items():
        path = os.path.join(CHUNKS_DIR, f"{coord[0]}_{coord[1]}.json")
        merge_chunk_file(path, footpaths)

    print(f"  row cz={cz}: footpaths={count} -> {len(by_chunk)} chunk files", file=sys.stderr)


def main():
    manifest_path = os.path.join(DATA_DIR, "manifest.json")
    if not os.path.exists(manifest_path):
        print("data/manifest.json not found -- run fetch_valley.py first", file=sys.stderr)
        sys.exit(1)
    manifest = load_json(manifest_path, {})
    lat0 = manifest["center"]["lat"]
    lon0 = manifest["center"]["lon"]
    m_lat = 111320.0
    m_lon = 111320.0 * (__import__("math").cos(__import__("math").radians(lat0)))

    def project(lat, lon):
        return [(lon - lon0) * m_lon, -(lat - lat0) * m_lat]

    os.makedirs(CACHE_DIR, exist_ok=True)
    seen_ids = load_json(SEEN_IDS_PATH, {})

    z_top_all = project(NORTH, WEST)[1]
    z_bot_all = project(SOUTH, WEST)[1]
    cz_min = chunk_of(0.0, z_top_all)[1]
    cz_max = chunk_of(0.0, z_bot_all)[1]
    rows = list(range(cz_min, cz_max + 1))
    print(f"footpath fetch: {len(rows)} rows, chunk_size={CHUNK_SIZE}m", file=sys.stderr)

    for n, cz in enumerate(rows):
        marker = os.path.join(CACHE_DIR, f"footpath_row_{cz}.done")
        if os.path.exists(marker):
            print(f"[{n + 1}/{len(rows)}] row cz={cz} already done, skipping", file=sys.stderr)
            continue
        t0 = time.time()
        print(f"[{n + 1}/{len(rows)}] row cz={cz} starting...", file=sys.stderr)
        fetch_row(cz, project, seen_ids)
        save_json(SEEN_IDS_PATH, seen_ids)
        with open(marker, "w") as f:
            f.write("done")
        print(f"[{n + 1}/{len(rows)}] row cz={cz} done in {time.time() - t0:.0f}s", file=sys.stderr)

    print("footpath fetch complete.", file=sys.stderr)


if __name__ == "__main__":
    main()
