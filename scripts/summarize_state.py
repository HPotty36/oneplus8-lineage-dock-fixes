#!/usr/bin/env python3
"""Print only the lines where USB/PD state changed in a docktest.sh state.txt."""
import re
import sys

BASE = {"qpnp_pon", "touchpanel", "touchpanel_kpd", "qti-haptics", "oplus,hall_tri_state_key",
        "gpio-keys", "qwerty", "kona-mtp-snd-card Headset Jack", "kona-mtp-snd-card Button Jack"}
PAT = re.compile(r"(\S+) up=(\S+) dr=\[(.*?)\] pr=\[(.*?)\] usb_online=(\S*) bat=(\S*) cur=(\S*)"
                 r"(?: rpm=\[(.*?)\])? usb=(.*?) inp=(.*)")

prev = None
for line in open(sys.argv[1], errors="replace"):
    m = PAT.match(line.rstrip())
    if not m:
        continue
    t, up, dr, pr, on, bat, cur, rpm, usb, inp = m.groups()
    extra = [x for x in re.findall(r'"([^"]*)"', inp) if x not in BASE]
    usbs = "|".join(sorted(p.strip() for p in usb.split("|") if p.strip()))
    key = (dr, pr, bat, usbs, tuple(sorted(set(extra))))
    if key != prev:
        print(f"{t} up={up} data=[{dr}] power=[{pr}] {bat:<11} usb={usbs}")
        if extra:
            print(f"{'':>9} input: {', '.join(sorted(set(extra)))}")
        prev = key
