#!/usr/bin/env python3
"""One-off cleanup: for chunk rows that fetch_valley.py has already merged real
data into, strip back out any leftover entries that came from the earlier
split_chunks.py downtown test set (merge_chunk_file appends rather than
replaces, so real + old-test data can end up stacked in the same file for
whichever rows overlap the original ~3.5km test area).

Usage: python3 tools/dedupe_test_chunks.py <cz row> [<cz row> ...]
Only touches rows you pass in -- run it after a row's "done" marker appears,
never on a row still being written by the background fetch.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(__file__))
from chunking import bucket_features

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
CHUNKS_DIR = os.path.join(DATA_DIR, "chunks")


def main():
    target_rows = set(int(x) for x in sys.argv[1:])
    if not target_rows:
        print("usage: dedupe_test_chunks.py <cz> [<cz> ...]", file=sys.stderr)
        sys.exit(1)

    with open(os.path.join(DATA_DIR, "kathmandu.json")) as f:
        d = json.load(f)
    old_chunks = bucket_features(d["roads"], d["buildings"], d.get("trees", []), d.get("greens", []))

    cleaned = []
    for (cx, cz), old_cell in old_chunks.items():
        if cz not in target_rows:
            continue
        path = os.path.join(CHUNKS_DIR, f"{cx}_{cz}.json")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            cur = json.load(f)
        changed = False
        for key in ("roads", "buildings", "trees", "greens"):
            old_remaining = list(old_cell.get(key, []))
            new_list = []
            for item in cur.get(key, []):
                if item in old_remaining:
                    old_remaining.remove(item)
                    changed = True
                    continue
                new_list.append(item)
            cur[key] = new_list
        if changed:
            with open(path, "w") as f:
                json.dump(cur, f)
            cleaned.append(f"{cx}_{cz}")

    print(f"cleaned {len(cleaned)} chunk files for rows {sorted(target_rows)}: {sorted(cleaned)}")


if __name__ == "__main__":
    main()
