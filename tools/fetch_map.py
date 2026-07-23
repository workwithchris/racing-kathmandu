#!/usr/bin/env python3
"""Fetch a larger slice of Kathmandu (roads + buildings from OpenStreetMap) plus
a real elevation grid (SRTM), project everything to local metres, and write the
compact JSON the Godot game loads."""
import json, math, time, urllib.request, urllib.parse, sys, os

# ~3.5 km box centred on Kathmandu (Thamel / Durbar / Ratna Park / New Baneshwor edge).
SOUTH, WEST, NORTH, EAST = 27.6940, 85.2980, 27.7260, 85.3340
GRID = 100  # elevation samples per side (GRID x GRID)

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

def overpass(query):
    data = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for attempt in range(3):
        for url in OVERPASS_MIRRORS:
            try:
                req = urllib.request.Request(url, data=data, headers=HEADERS)
                with urllib.request.urlopen(req, timeout=180) as r:
                    return json.load(r)
            except Exception as ex:
                last = ex
                print(f"    mirror {url.split('/')[2]} failed ({ex}); trying next...", file=sys.stderr)
                time.sleep(3)
    raise last

def fetch(kind, selector):
    q = (f"[out:json][timeout:150];(way{selector}"
         f"({SOUTH},{WEST},{NORTH},{EAST}););(._;>;);out;")
    print(f"  fetching {kind}...", file=sys.stderr)
    return overpass(q)

def elevation(coords):
    """Return elevations for [(lat,lon),...]. Try open-elevation (bulk), else opentopodata."""
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

def poly_area(pts):
    a = 0.0
    for i in range(len(pts) - 1):
        a += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1]
    return abs(a) * 0.5

def main():
    lat0 = (SOUTH + NORTH) / 2.0
    lon0 = (WEST + EAST) / 2.0
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))

    def project(lat, lon):
        return [(lon - lon0) * m_lon, -(lat - lat0) * m_lat]  # north = -Z

    roads_raw = fetch("roads", '["highway"]')
    bld_raw = fetch("buildings", '["building"]')

    def index_nodes(d):
        return {e["id"]: (e["lat"], e["lon"]) for e in d["elements"] if e["type"] == "node"}
    rn = index_nodes(roads_raw)
    bn = index_nodes(bld_raw)

    roads = []
    for e in roads_raw["elements"]:
        if e["type"] != "way":
            continue
        w = ROAD_W.get(e.get("tags", {}).get("highway"))
        if w is None:
            continue
        pts = [project(*rn[n]) for n in e["nodes"] if n in rn]
        if len(pts) >= 2:
            roads.append({"w": w, "p": pts})

    buildings = []
    for e in bld_raw["elements"]:
        if e["type"] != "way":
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
        buildings.append({"h": max(3.0, min(h, 45.0)), "p": pts})

    # Elevation grid over the bbox (rows north->south, cols west->east).
    print("  building elevation grid...", file=sys.stderr)
    coords = []
    for i in range(GRID):
        lat = NORTH + (SOUTH - NORTH) * i / (GRID - 1)
        for j in range(GRID):
            lon = WEST + (EAST - WEST) * j / (GRID - 1)
            coords.append((round(lat, 6), round(lon, 6)))
    elev = elevation(coords)
    base = min(elev)
    heights = [round(e - base, 2) for e in elev]

    x_west = (WEST - lon0) * m_lon
    x_east = (EAST - lon0) * m_lon
    z_north = -(NORTH - lat0) * m_lat
    z_south = -(SOUTH - lat0) * m_lat

    out = {
        "center": {"lat": lat0, "lon": lon0},
        "roads": roads,
        "buildings": buildings,
        "terrain": {
            "nx": GRID, "nz": GRID,
            "minx": x_west, "maxx": x_east,
            "minz": z_north, "maxz": z_south,
            "base_elev": base, "h": heights,
        },
    }
    dest = "/Users/apple/Desktop/untitled folder/racing/data"
    os.makedirs(dest, exist_ok=True)
    with open(os.path.join(dest, "kathmandu.json"), "w") as f:
        json.dump(out, f)
    print(f"roads={len(roads)} buildings={len(buildings)} "
          f"elev_min={base:.0f}m range={max(heights):.0f}m", file=sys.stderr)

if __name__ == "__main__":
    main()
