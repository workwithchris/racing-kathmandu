"""Shared spatial-chunking helpers for the valley-wide streaming map format.

Both tools/split_chunks.py (re-chunks the existing small downtown dataset for
fast local testing) and tools/fetch_valley.py (the real whole-valley fetch)
import this so the on-disk chunk format and chunk-size math never drift apart.

Chunk coordinates are (cx, cz) = floor(x / CHUNK_SIZE), floor(z / CHUNK_SIZE) in
the same local-metres space `project()` already produces (origin at the map's
lat/lon centre). Godot reads CHUNK_SIZE back out of manifest.json at runtime,
so it is the single source of truth here, not duplicated in GDScript.
"""
import math

CHUNK_SIZE = 1000.0  # metres per chunk cell


def chunk_of(x: float, z: float) -> tuple:
    return (math.floor(x / CHUNK_SIZE), math.floor(z / CHUNK_SIZE))


def split_polyline_by_chunk(pts: list) -> list:
    """Split a road polyline into runs that each live in one chunk, only
    cutting at points where the polyline actually crosses a chunk boundary
    (most roads are far shorter than a chunk and come back as a single run).
    Returns [(chunk_coord, [pts...]), ...]; boundary points are duplicated
    across the two runs they join so there's no gap in the rendered ribbon.
    """
    runs = []
    if len(pts) < 2:
        return runs
    cur_chunk = chunk_of(pts[0][0], pts[0][1])
    cur_pts = [pts[0]]
    for i in range(1, len(pts)):
        p = pts[i]
        c = chunk_of(p[0], p[1])
        cur_pts.append(p)
        if c != cur_chunk:
            runs.append((cur_chunk, cur_pts))
            cur_chunk = c
            cur_pts = [p]
    if len(cur_pts) >= 2:
        runs.append((cur_chunk, cur_pts))
    return runs


def bucket_features(roads: list, buildings: list, trees: list, greens: list) -> dict:
    """Group already-projected (local metres) features into per-chunk buckets.

    roads: [{"w": float, "p": [[x,z],...]}, ...]
    buildings: [{"h": float, "p": [[x,z],...]}, ...]
    trees: [[x, z, scale], ...]
    greens: [{"p": [[x,z],...]}, ...]
    """
    chunks: dict = {}

    def cell(coord):
        return chunks.setdefault(coord, {"roads": [], "buildings": [], "trees": [], "greens": []})

    for r in roads:
        for coord, run_pts in split_polyline_by_chunk(r["p"]):
            cell(coord)["roads"].append({"w": r["w"], "p": run_pts})

    for b in buildings:
        pts = b["p"]
        cx = sum(p[0] for p in pts) / len(pts)
        cz = sum(p[1] for p in pts) / len(pts)
        cell(chunk_of(cx, cz))["buildings"].append(b)

    for t in trees:
        cell(chunk_of(t[0], t[1]))["trees"].append(t)

    for g in greens:
        pts = g["p"]
        cell(chunk_of(pts[0][0], pts[0][1]))["greens"].append(g)

    return chunks
