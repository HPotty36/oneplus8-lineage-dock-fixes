#!/usr/bin/env python3
"""Convert a raw /dev/kmsg capture to "[seconds] message" lines."""
import re
import sys

src = open(sys.argv[1], errors="replace") if len(sys.argv) > 1 else sys.stdin
for line in src:
    m = re.match(r"(\d+),(\d+),(\d+),[^;]*;(.*)", line.rstrip("\n"))
    if m:
        print(f"[{int(m.group(3)) / 1e6:10.3f}] {m.group(4)}")
