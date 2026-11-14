#!/usr/bin/env python3
"""One-off: copy the third artwork batch (LAST_IMAGES plus three DUMP picks) into art/masters.

Each source's full sha256 is checked, then it is scaled as import_masters.py does (the "full"
set stays full size, the rest go to 4x the largest box side among the slots using it).
Usage: import_batch3.py [new_images dir]
"""
import glob, hashlib, json, os, sys
from PIL import Image

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/Users/brian/git/nighttime_timelapse_airplane_remover/new_images"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "masters")
FULL = {"BR-5", "BR-7a", "BR-7b", "BR-7c"}
L, D = "LAST_IMAGES/", "DUMP/*/images/"

TABLE = {
    "BR-6": (L + "BR-6.png", "692e4833bae7dec1b938facc4797570aeaaea85bfee9e0191ba16a50d2f9c130"),
    "BR-7b": (L + "BR-7b.png", "178ec78ad0a61400eb32eff83c56d6554a665d9148f6e0b3c45d43315966d97b"),
    "BR-7c": (L + "BR-7c.png", "b3d2e474ff64f17c5445e80e75f7b34f97e7726a3555a9bc9451627dbf760e2d"),
    "WL-1": (L + "WL-1.png", "e48c9f598b5307fc0a2f27d1e035199d92b7a99cd4950b652318a92033f5c767"),
    "PR-1": (D + "0227_a_high_quality_glossy_cartoon_3d_vector_mascot_ill.png", "63f6776cdd25cc044647f3df6517269e5ae94b518920a3f78c5a9d1690d21f91"),
    "PR-5a": (L + "PR-5a.png", "9ba9d5295b353b89ea05a0cd4b88c27aff86314ef38054ebc088087652d1c145"),
    "PR-5b": (L + "PR-5b.png", "2675d9a20bc7340cabc48225788bf1216c78bf9e5569ae78eda9c54ec8d60308"),
    "TL-7": (L + "TL-7.png", "2e7bb80299a5502229c338576339149a7a5aaad0d8aefd35111335592441a089"),
    "WL-3": (L + "WL-3.png", "2f529f2242359f2664ba7ae8480da6c735624ec76ebbfc264f93d7772bfbf883"),
    "SU-7a": (D + "0206_a_glowing_neon_style_app_icon_a_dark_nearly_black.png", "315ba3ef5f1fb0afa3da3fc3bd22c9a0edf90201c64d6e9252e9195f1d385741"),
    "SU-7b": (D + "0251_a_neon_glow_icon_on_black_a_glowing_purple_pink_n.png", "667cf2322d7fc8493862e2ab5c0697ba87e6a038a408f0d739617b56e5a82dfa"),
    "SU-7c": (L + "SU-7c.png", "ab2d7b910edd5b9e4bec4fa46fe3ccc79af5dd28ed82ce699dddcec3cfc6b22e"),
    "ST-5": (L + "ST-5.png", "63249567a3efe532f4d0bbdfb12a339c774cfc620606d7cbad1b8c7380bd7a94"),
    "ST-6": (L + "ST-6.png", "b3a35e8712a861ef9f32ac9767bb45cd23754c57e1df814f8abcb0b47411ccc5"),
}

slots = json.load(open(os.path.join(HERE, "slots.json")))["slots"]
maxpx = {}
for s in slots:
    m = round(4 * max(s.get("width") or 0, s.get("height") or 0))
    maxpx[s["source"]] = max(maxpx.get(s["source"], 0), m)

for mid, (rel, digest) in sorted(TABLE.items()):
    found = glob.glob(os.path.join(ROOT, rel))
    assert len(found) == 1, (mid, rel, found)
    assert hashlib.sha256(open(found[0], "rb").read()).hexdigest() == digest, mid
    im = Image.open(found[0]); im.load()
    if mid not in FULL:
        lim = maxpx[mid]
        if max(im.size) > lim:
            r = lim / max(im.size)
            im = im.resize((round(im.width * r), round(im.height * r)), Image.LANCZOS)
    im.save(os.path.join(OUT, mid + ".png"), optimize=True)
    print(mid, im.size, im.mode)
