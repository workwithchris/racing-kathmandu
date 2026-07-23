#!/usr/bin/env python3
"""Add trees + green areas to the existing kathmandu.json without re-fetching the
big building/elevation set. Pulls OSM tree nodes and park/green polygons, projects
them with the same origin, scatters extra trees inside green areas, and merges."""
import json, math, random, urllib.request, urllib.parse, sys, time

SOUTH, WEST, NORTH, EAST = 27.6940, 85.2980, 27.7260, 85.3340
MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
HEADERS = {"User-Agent": "godot-racing-learning-project/1.0 (personal use)"}
DEST = "/Users/apple/Desktop/untitled folder/racing/data/kathmandu.json"
MAX_TREES = 12000
random.seed(7)

# trees per square metre for scattering inside green polygons, by tag value.
DENSITY = {
    "park": 1 / 55.0, "garden": 1 / 45.0, "forest": 1 / 25.0, "wood": 1 / 25.0,
    "scrub": 1 / 40.0, "grass": 1 / 140.0, "meadow": 1 / 160.0, "grassland": 1 / 120.0,
    "recreation_ground": 1 / 120.0, "village_green": 1 / 110.0, "pitch": 0.0,
}

def overpass(query):
    data = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for _ in range(3):
        for url in MIRRORS:
            try:
                req = urllib.request.Request(url, data=data, headers=HEADERS)
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.load(r)
            except Exception as ex:
                last = ex
                print(f"    {url.split('/')[2]} failed ({ex})", file=sys.stderr)
                time.sleep(3)
    raise last

def poly_area(pts):
    a = 0.0
    for i in range(len(pts) - 1):
        a += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1]
    return abs(a) * 0.5

def in_poly(x, z, pts):
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

def main():
    with open(DEST) as f:
        data = json.load(f)
    lat0 = data["center"]["lat"]
    lon0 = data["center"]["lon"]
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))

    def project(lat, lon):
        return [(lon - lon0) * m_lon, -(lat - lat0) * m_lat]

    q = (f"[out:json][timeout:120];("
         f'node["natural"="tree"]({SOUTH},{WEST},{NORTH},{EAST});'
         f'way["leisure"~"^(park|garden|pitch|recreation_ground)$"]({SOUTH},{WEST},{NORTH},{EAST});'
         f'way["natural"~"^(wood|scrub|grassland)$"]({SOUTH},{WEST},{NORTH},{EAST});'
         f'way["landuse"~"^(forest|grass|meadow|recreation_ground|village_green)$"]({SOUTH},{WEST},{NORTH},{EAST});'
         f");(._;>;);out;")
    print("  fetching trees + green areas...", file=sys.stderr)
    raw = overpass(q)

    nodes = {e["id"]: (e["lat"], e["lon"]) for e in raw["elements"] if e["type"] == "node"}

    trees = []  # [x, z, scale]
    for e in raw["elements"]:
        if e["type"] == "node" and e.get("tags", {}).get("natural") == "tree":
            x, z = project(e["lat"], e["lon"])
            trees.append([round(x, 1), round(z, 1), round(random.uniform(0.9, 1.5), 2)])

    greens = []
    for e in raw["elements"]:
        if e["type"] != "way":
            continue
        tags = e.get("tags", {})
        tag = (tags.get("leisure") or tags.get("natural") or tags.get("landuse") or "")
        pts = [project(*nodes[n]) for n in e["nodes"] if n in nodes]
        if len(pts) < 4:
            continue
        greens.append({"p": [[round(a, 1), round(b, 1)] for a, b in pts]})
        # Scatter trees inside.
        dens = DENSITY.get(tag, 0.0)
        if dens <= 0.0:
            continue
        area = poly_area(pts)
        count = min(int(area * dens), 1500)
        xs = [p[0] for p in pts]; zs = [p[1] for p in pts]
        x0, x1, z0, z1 = min(xs), max(xs), min(zs), max(zs)
        tries = 0
        placed = 0
        while placed < count and tries < count * 12:
            tries += 1
            rx = random.uniform(x0, x1); rz = random.uniform(z0, z1)
            if in_poly(rx, rz, pts):
                trees.append([round(rx, 1), round(rz, 1), round(random.uniform(0.8, 1.4), 2)])
                placed += 1
        if len(trees) >= MAX_TREES:
            break

    if len(trees) > MAX_TREES:
        random.shuffle(trees)
        trees = trees[:MAX_TREES]

    data["trees"] = trees
    data["greens"] = greens
    with open(DEST, "w") as f:
        json.dump(data, f)
    print(f"trees={len(trees)} greens={len(greens)}", file=sys.stderr)

if __name__ == "__main__":
    main()
