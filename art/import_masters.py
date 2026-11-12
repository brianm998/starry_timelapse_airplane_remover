#!/usr/bin/env python3
"""One-off: copy the used first_41 images into art/masters (sha256-checked, downscaled)."""
import csv, hashlib, sys, os
from PIL import Image
src = sys.argv[1]; out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "masters")
sha = {r["asset_id"]: r["sha256"] for r in csv.DictReader(open(os.path.join(src, "MANIFEST.csv")))}
skip = {"TL-7", "IM-2a", "IM-2b", "SU-3b", "WL-3"}
full = {"BR-5", "BR-7a", "BR-7b", "BR-7c"}
icon = {"BR-1", "BR-2"}
files = {k: k for k in sha if k not in skip}
files["SU-3b"] = "WL-3"
import json
slots = json.load(open(os.path.join(out, "..", "slots.json")))["slots"]
maxpx = {}
for s in slots:
    w = s.get("width") or 0; h = s.get("height") or 0
    m = round(4 * max(w, h))
    # full-height-driven cutouts: height only
    maxpx[s["source"]] = max(maxpx.get(s["source"], 0), m)
for mid, fn in sorted(files.items()):
    data = open(os.path.join(src, fn + ".png"), "rb").read()
    expect = sha.get(fn)
    assert hashlib.sha256(data).hexdigest() == expect, fn
    im = Image.open(os.path.join(src, fn + ".png")); im.load()
    if mid in full: pass
    else:
        lim = 1024 if mid in icon else maxpx[mid]
        if max(im.size) > lim:
            r = lim / max(im.size)
            im = im.resize((round(im.width*r), round(im.height*r)), Image.LANCZOS)
    im.save(os.path.join(out, mid + ".png"), optimize=True)
    print(mid, im.size, im.mode)
