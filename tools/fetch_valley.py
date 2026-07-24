#!/usr/bin/env python3
"""Fetch the WHOLE Kathmandu Valley (roads, buildings, trees, green areas, and
a shared elevation grid) from OpenStreetMap + SRTM, and write it straight into
the chunked streaming format Godot reads (data/manifest.json, data/terrain.json,
data/chunks/{cx}_{cz}.json) -- the same format tools/split_chunks.py produces
from the old small downtown dataset.

This covers ~568 km^2 (vs. the original ~12 km^2 downtown box), so unlike
fetch_map.py this issues many smaller Overpass queries -- one row of chunks at
a time, north to south -- instead of one giant query, to stay under Overpass's
per-request size/timeout limits. It is resumable: each row is marked done only
after its chunk files are written, so a killed/interrupted run can just be
re-launched and it'll skip finished rows and continue.

Expect this to take a long time (likely 1-3+ hours) against the free public
Overpass/elevation mirrors. Run it in the background and watch stderr.
"""
import json, math, os, sys, time, urllib.request, urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
from chunking import CHUNK_SIZE, chunk_of, bucket_features

# Whole Kathmandu Valley, centred on the same point the original downtown box
# used (27.71, 85.316) so old and new chunk coordinates share one origin.
SOUTH, WEST, NORTH, EAST = 27.61, 85.186, 27.81, 85.446
GRID = 400  # shared elevation grid resolution (GRID x GRID over the whole valley)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
CHUNKS_DIR = os.path.join(DATA_DIR, "chunks")
CACHE_DIR = os.path.join(DATA_DIR, "valley_cache")
SEEN_IDS_PATH = os.path.join(CACHE_DIR, "seen_ids.json")

OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
OPEN_ELEV = "https://api.open-elevation.com/api/v1/lookup"
OPENTOPO = "https://api.opentopodata.org/v1/srtm30m"
HEADERS = {"User-Agent": "godot-racing-learning-project/1.0 (personal use)"}

ROAD_W = {
    "motorway": 14, "trunk": 13, "primary": 11, "secondary": 9, "tertiary": 7.5,
    "unclassified": 6, "residential": 5.5, "living_street": 5, "service": 4,
    "pedestrian": 4.5, "primary_link": 9, "secondary_link": 7.5, "tertiary_link": 6,
    "motorway_link": 9, "trunk_link": 9,
}
GREEN_DENSITY = {
    "park": 1 / 55.0, "garden": 1 / 45.0, "forest": 1 / 25.0, "wood": 1 / 25.0,
    "scrub": 1 / 40.0, "grass": 1 / 140.0, "meadow": 1 / 160.0, "grassland": 1 / 120.0,
    "recreation_ground": 1 / 120.0, "village_green": 1 / 110.0, "pitch": 0.0,
}
MAX_TREES_PER_ROW = 4000
import random
random.seed(7)


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


def elevation(coords: list) -> list:
    out = []
    try:
        for i in range(0, len(coords), 900):
            chunk = coords[i:i + 900]
            body = json.dumps({"locations": [{"latitude": a, "longitude": b} for a, b in chunk]}).encode()
            req = urllib.request.Request(OPEN_ELEV, data=body,
                                          headers={**HEADERS, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                res = json.load(r)["results"]
            out.extend(e["elevation"] for e in res)
            print(f"    open-elevation {i + len(chunk)}/{len(coords)}", file=sys.stderr)
            time.sleep(0.4)
        return out
    except Exception as ex:
        print(f"  open-elevation failed ({ex}); falling back to opentopodata...", file=sys.stderr)
    out = []
    for i in range(0, len(coords), 100):
        chunk = coords[i:i + 100]
        locs = "|".join(f"{a},{b}" for a, b in chunk)
        url = f"{OPENTOPO}?locations={urllib.parse.quote(locs)}"
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=60) as r:
            res = json.load(r)["results"]
        out.extend((e["elevation"] if e["elevation"] is not None else 0.0) for e in res)
        print(f"    opentopodata {i + len(chunk)}/{len(coords)}", file=sys.stderr)
        time.sleep(1.05)
    return out


def poly_area(pts: list) -> float:
    a = 0.0
    for i in range(len(pts) - 1):
        a += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1]
    return abs(a) * 0.5


def in_poly(x: float, z: float, pts: list) -> bool:
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, zi = pts[i]
        xj, zj = pts[j]
        if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi + 1e-9) + xi:
            inside = not inside
        j = i
    return inside


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


def merge_chunk_file(path: str, cell: dict) -> None:
    existing = load_json(path, {"roads": [], "buildings": [], "trees": [], "greens": []})
    existing["roads"].extend(cell["roads"])
    existing["buildings"].extend(cell["buildings"])
    existing["trees"].extend(cell["trees"])
    existing["greens"].extend(cell["greens"])
    save_json(path, existing)


def fetch_elevation_grid(project):
    terrain_path = os.path.join(DATA_DIR, "terrain.json")
    if os.path.exists(terrain_path):
        print("terrain.json already present, skipping elevation fetch", file=sys.stderr)
        return
    print("fetching shared elevation grid...", file=sys.stderr)
    coords = []
    for i in range(GRID):
        lat = NORTH + (SOUTH - NORTH) * i / (GRID - 1)
        for j in range(GRID):
            lon = WEST + (EAST - WEST) * j / (GRID - 1)
            coords.append((round(lat, 6), round(lon, 6)))
    elev = elevation(coords)
    base = min(elev)
    heights = [round(e - base, 2) for e in elev]

    x_west = project(NORTH, WEST)[0]  # project() only needs lon for x; lat arg unused there
    x_east = project(NORTH, EAST)[0]
    z_north = project(NORTH, WEST)[1]
    z_south = project(SOUTH, WEST)[1]

    terrain = {
        "nx": GRID, "nz": GRID,
        "minx": x_west, "maxx": x_east,
        "minz": z_north, "maxz": z_south,
        "base_elev": base, "h": heights,
    }
    save_json(terrain_path, terrain)
    print(f"  terrain: elev_min={base:.0f}m range={max(heights):.0f}m", file=sys.stderr)


def fetch_row(cz: int, project, seen_ids: dict) -> None:
    """Fetch + write everything for one 1-chunk-tall east-west strip of the valley."""
    z_top = cz * CHUNK_SIZE
    z_bot = (cz + 1) * CHUNK_SIZE
    # Invert the projection (north = -Z) back to a lat band, with a small
    # overlap so features exactly on the seam aren't missed by either row.
    lat0 = (SOUTH + NORTH) / 2.0
    m_lat = 111320.0
    row_north = lat0 - z_top / m_lat
    row_south = lat0 - z_bot / m_lat
    pad = 0.0015  # ~165m overlap; dedup by OSM id prevents double-drawing
    row_north = min(NORTH, row_north + pad)
    row_south = max(SOUTH, row_south - pad)

    bbox = f"({row_south},{WEST},{row_north},{EAST})"

    print(f"  row cz={cz}: fetching roads+buildings...", file=sys.stderr)
    roads_raw = overpass(f'[out:json][timeout:200];(way["highway"]{bbox};);(._;>;);out;')
    bld_raw = overpass(f'[out:json][timeout:200];(way["building"]{bbox};);(._;>;);out;')
    print(f"  row cz={cz}: fetching trees+greens...", file=sys.stderr)
    tg_raw = overpass(
        "[out:json][timeout:200];("
        f'node["natural"="tree"]{bbox};'
        f'way["leisure"~"^(park|garden|pitch|recreation_ground)$"]{bbox};'
        f'way["natural"~"^(wood|scrub|grassland)$"]{bbox};'
        f'way["landuse"~"^(forest|grass|meadow|recreation_ground|village_green)$"]{bbox};'
        ");(._;>;);out;"
    )

    def index_nodes(d):
        return {e["id"]: (e["lat"], e["lon"]) for e in d["elements"] if e["type"] == "node"}

    rn = index_nodes(roads_raw)
    bn = index_nodes(tg_raw)
    bn.update(index_nodes(bld_raw))

    roads = []
    for e in roads_raw["elements"]:
        if e["type"] != "way":
            continue
        key = f"way/{e['id']}"
        if key in seen_ids:
            continue
        w = ROAD_W.get(e.get("tags", {}).get("highway"))
        if w is None:
            continue
        pts = [project(*rn[n]) for n in e["nodes"] if n in rn]
        if len(pts) >= 2:
            seen_ids[key] = True
            roads.append({"w": w, "p": pts})

    buildings = []
    for e in bld_raw["elements"]:
        if e["type"] != "way":
            continue
        key = f"way/{e['id']}"
        if key in seen_ids:
            continue
        tags = e.get("tags", {})
        if "building" not in tags:
            continue
        pts = [project(*bn[n]) for n in e["nodes"] if n in bn]
        if len(pts) < 4 or poly_area(pts) < 8.0:
            continue
        h = None
        if tags.get("height"):
            try: h = float(str(tags["height"]).split()[0])
            except ValueError: pass
        if h is None and tags.get("building:levels"):
            try: h = float(tags["building:levels"]) * 3.0
            except ValueError: pass
        if h is None:
            h = 7.0
        seen_ids[key] = True
        buildings.append({"h": max(3.0, min(h, 45.0)), "p": pts})

    trees = []
    greens = []
    for e in tg_raw["elements"]:
        if e["type"] == "node" and e.get("tags", {}).get("natural") == "tree":
            key = f"node/{e['id']}"
            if key in seen_ids:
                continue
            seen_ids[key] = True
            x, z = project(e["lat"], e["lon"])
            trees.append([round(x, 1), round(z, 1), round(random.uniform(0.9, 1.5), 2)])
    for e in tg_raw["elements"]:
        if e["type"] != "way":
            continue
        key = f"way/{e['id']}"
        if key in seen_ids:
            continue
        tags = e.get("tags", {})
        tag = tags.get("leisure") or tags.get("natural") or tags.get("landuse") or ""
        pts = [project(*bn[n]) for n in e["nodes"] if n in bn]
        if len(pts) < 4:
            continue
        seen_ids[key] = True
        greens.append({"p": [[round(a, 1), round(b, 1)] for a, b in pts]})
        dens = GREEN_DENSITY.get(tag, 0.0)
        if dens <= 0.0 or len(trees) >= MAX_TREES_PER_ROW:
            continue
        area = poly_area(pts)
        count = min(int(area * dens), 1200)
        xs = [p[0] for p in pts]; zs = [p[1] for p in pts]
        x0, x1, z0, z1 = min(xs), max(xs), min(zs), max(zs)
        tries = 0
        placed = 0
        while placed < count and tries < count * 12 and len(trees) < MAX_TREES_PER_ROW:
            tries += 1
            rx = random.uniform(x0, x1); rz = random.uniform(z0, z1)
            if in_poly(rx, rz, pts):
                trees.append([round(rx, 1), round(rz, 1), round(random.uniform(0.8, 1.4), 2)])
                placed += 1

    chunks = bucket_features(roads, buildings, trees, greens)
    os.makedirs(CHUNKS_DIR, exist_ok=True)
    for (cx, cell_cz), cell in chunks.items():
        path = os.path.join(CHUNKS_DIR, f"{cx}_{cell_cz}.json")
        merge_chunk_file(path, cell)

    print(f"  row cz={cz}: roads={len(roads)} buildings={len(buildings)} "
          f"trees={len(trees)} greens={len(greens)} -> {len(chunks)} chunk files", file=sys.stderr)


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)

    lat0 = (SOUTH + NORTH) / 2.0
    lon0 = (WEST + EAST) / 2.0
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))

    def project(lat, lon):
        return [(lon - lon0) * m_lon, -(lat - lat0) * m_lat]  # north = -Z

    fetch_elevation_grid(project)

    manifest = {
        "center": {"lat": lat0, "lon": lon0},
        "chunk_size": CHUNK_SIZE,
        "terrain": "res://data/terrain.json",
    }
    save_json(os.path.join(DATA_DIR, "manifest.json"), manifest)

    seen_ids = load_json(SEEN_IDS_PATH, {})

    z_top_all = project(NORTH, WEST)[1]
    z_bot_all = project(SOUTH, WEST)[1]
    cz_min = chunk_of(0.0, z_top_all)[1]
    cz_max = chunk_of(0.0, z_bot_all)[1]
    rows = list(range(cz_min, cz_max + 1))
    print(f"valley fetch: {len(rows)} rows, chunk_size={CHUNK_SIZE}m", file=sys.stderr)

    for n, cz in enumerate(rows):
        marker = os.path.join(CACHE_DIR, f"row_{cz}.done")
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

    print("valley fetch complete.", file=sys.stderr)


if __name__ == "__main__":
    main()
