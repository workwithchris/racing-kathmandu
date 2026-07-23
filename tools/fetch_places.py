#!/usr/bin/env python3
"""Fetch named places (POIs + neighbourhoods) in the Kathmandu bbox from OSM and
write data/places.json — a searchable list of {n:name, x, z, c:category}."""
import json, math, urllib.request, urllib.parse, sys, time

SOUTH, WEST, NORTH, EAST = 27.6940, 85.2980, 27.7260, 85.3340
MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
HEADERS = {"User-Agent": "godot-racing-learning-project/1.0 (personal use)"}
SRC = "/Users/apple/Desktop/untitled folder/racing/data/kathmandu.json"
DEST = "/Users/apple/Desktop/untitled folder/racing/data/places.json"
MAX_PLACES = 5000

def overpass(query):
    data = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for _ in range(3):
        for url in MIRRORS:
            try:
                req = urllib.request.Request(url, data=data, headers=HEADERS)
                with urllib.request.urlopen(req, timeout=150) as r:
                    return json.load(r)
            except Exception as ex:
                last = ex
                print(f"    {url.split('/')[2]} failed ({ex})", file=sys.stderr)
                time.sleep(3)
    raise last

def main():
    with open(SRC) as f:
        center = json.load(f)["center"]
    lat0, lon0 = center["lat"], center["lon"]
    m_lat = 111320.0
    m_lon = 111320.0 * math.cos(math.radians(lat0))

    def project(lat, lon):
        return [round((lon - lon0) * m_lon, 1), round(-(lat - lat0) * m_lat, 1)]

    bb = f"({SOUTH},{WEST},{NORTH},{EAST})"
    q = ("[out:json][timeout:150];("
         f'node["name"]["amenity"]{bb};'
         f'node["name"]["tourism"]{bb};'
         f'node["name"]["historic"]{bb};'
         f'node["name"]["shop"]{bb};'
         f'node["name"]["leisure"]{bb};'
         f'node["name"]["office"~"government"]{bb};'
         f'node["name"]["place"~"suburb|neighbourhood|quarter|square"]{bb};'
         f'way["name"]["amenity"]{bb};'
         f'way["name"]["tourism"]{bb};'
         f'way["name"]["historic"]{bb};'
         f'way["name"]["leisure"]{bb};'
         ");out center;")
    print("  fetching named places...", file=sys.stderr)
    raw = overpass(q)

    seen = {}  # (name_lower, rounded x, rounded z) -> place
    for e in raw["elements"]:
        tags = e.get("tags", {})
        name = tags.get("name")
        if not name or len(name) > 60:
            continue
        if e["type"] == "node":
            lat, lon = e.get("lat"), e.get("lon")
        else:
            c = e.get("center")
            lat, lon = (c["lat"], c["lon"]) if c else (None, None)
        if lat is None:
            continue
        x, z = project(lat, lon)
        cat = (tags.get("amenity") or tags.get("tourism") or tags.get("historic")
               or tags.get("shop") or tags.get("leisure") or tags.get("place")
               or tags.get("office") or "place")
        key = (name.lower(), round(x / 40), round(z / 40))
        if key in seen:
            continue
        seen[key] = {"n": name, "x": x, "z": z, "c": cat}

    places = list(seen.values())
    # Prefer notable categories if we have to cap.
    priority = {"place": 0, "temple": 0, "hospital": 0, "attraction": 0, "hotel": 0}
    places.sort(key=lambda p: priority.get(p["c"], 5))
    places = places[:MAX_PLACES]

    with open(DEST, "w") as f:
        json.dump({"places": places}, f, ensure_ascii=False)
    print(f"places={len(places)}", file=sys.stderr)
    # show a few samples
    for p in places[:8]:
        print(f"    {p['n']} ({p['c']})", file=sys.stderr)

if __name__ == "__main__":
    main()
