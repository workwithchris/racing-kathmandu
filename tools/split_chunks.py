#!/usr/bin/env python3
"""Re-chunk the existing data/kathmandu.json (small downtown fetch) into the
new streaming format: data/manifest.json + data/terrain.json + data/chunks/*.json.

This exists so the Godot chunk-streaming runtime can be built and tested today
against real data, without waiting on tools/fetch_valley.py's much longer
whole-valley network fetch. Once that finishes, its chunk files/manifest can
simply replace (or merge with) what this script produces -- both write the
exact same on-disk format.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from chunking import CHUNK_SIZE, bucket_features

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "data", "kathmandu.json")
DATA_DIR = os.path.join(ROOT, "data")
CHUNKS_DIR = os.path.join(DATA_DIR, "chunks")


def main():
    with open(SRC) as f:
        d = json.load(f)

    os.makedirs(CHUNKS_DIR, exist_ok=True)

    with open(os.path.join(DATA_DIR, "terrain.json"), "w") as f:
        json.dump(d["terrain"], f)

    manifest = {
        "center": d["center"],
        "chunk_size": CHUNK_SIZE,
        "terrain": "res://data/terrain.json",
    }
    with open(os.path.join(DATA_DIR, "manifest.json"), "w") as f:
        json.dump(manifest, f)

    chunks = bucket_features(d["roads"], d["buildings"], d.get("trees", []), d.get("greens", []))
    for (cx, cz), cell in chunks.items():
        path = os.path.join(CHUNKS_DIR, f"{cx}_{cz}.json")
        with open(path, "w") as f:
            json.dump(cell, f)

    print(f"wrote {len(chunks)} chunks to {CHUNKS_DIR}", file=sys.stderr)
    print(f"chunk_size={CHUNK_SIZE}m", file=sys.stderr)


if __name__ == "__main__":
    main()
