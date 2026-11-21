#!/usr/bin/env python3
"""Pick a LineageOS instantnoodle build and print its boot.img / manifest info.

Usage: pick_build.py [YYYYMMDD]
Prints KEY=VALUE lines (suitable for $GITHUB_OUTPUT).
"""
import json
import sys
import urllib.request

API = "https://download.lineageos.org/api/v2/devices/instantnoodle/builds"


def main():
    want = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    with urllib.request.urlopen(API, timeout=60) as r:
        builds = json.load(r)
    builds.sort(key=lambda b: b["datetime"], reverse=True)
    for b in builds:
        date = b["date"].replace("-", "")
        if want and date != want:
            continue
        files = {f["filename"]: f for f in b["files"]}
        if "boot.img" not in files or "build-manifest.xml" not in files:
            continue
        zipname = next(f["filename"] for f in b["files"] if f["filename"].endswith(".zip"))
        print(f"date={date}")
        print(f"version={b['version']}")
        print(f"zip={zipname}")
        print(f"boot_url={files['boot.img']['url']}")
        print(f"boot_sha256={files['boot.img']['sha256']}")
        print(f"manifest_url={files['build-manifest.xml']['url']}")
        print(f"manifest_sha256={files['build-manifest.xml']['sha256']}")
        return 0
    print(f"no build found (wanted {want or 'latest'})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
