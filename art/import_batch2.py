#!/usr/bin/env python3
"""One-off: copy the second artwork batch from the DUMP into art/masters.

Each file is found under DUMP/*/images/, its sha256 checked against the DUMP manifest,
downscaled to 4x the largest box side among the slots using it, and saved as <ID>.png.
Usage: import_batch2.py [DUMP dir]
"""
import csv, glob, hashlib, json, os, sys
from PIL import Image

DUMP = sys.argv[1] if len(sys.argv) > 1 else "/Users/brian/git/nighttime_timelapse_airplane_remover/new_images/DUMP"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "masters")

TABLE = {
    "WL-2": "0058_WL-2.png",
    "IM-2a": "0046_IM-2a.png",
    "IM-2b": "0248_a_neon_glow_app_style_icon_a_black_dark_backgroun.png",
    "IM-2c": "0263_a_neon_style_rounded_square_app_icon_like_the_othe.png",
    "PR-3b": "0245_a_neon_glow_app_icon_rounded_square_dark_navy_bla.png",
    "PR-3c": "0164_a_clean_neon_icon_on_a_dark_black_very_deep_purple.png",
    "PR-3d": "0253_a_neon_glowing_app_icon_rounded_square_dark_gradi.png",
    "PR-3e": "0259_a_neon_glowing_icon_on_a_dark_nearly_black_backgro.png",
    "PR-3f": "0203_a_glowing_neon_icon_on_a_dark_black_purple_backgro.png",
    "HZ-1a": "0304_a_vivid_detailed_digital_illustration_of_a_night.png",
    "HZ-1b": "0307_a_vivid_neon_styled_night_sky_landscape_like_hz_1a.png",
    "HZ-1c": "0306_a_vivid_neon_sci_fi_night_sky_landscape_similar_t.png",
    "HZ-2": "0158_a_clean_infographic_like_sequence_with_four_rounde.png",
    "ST-2": "0170_a_clean_stylized_infographic_on_a_dark_navy_black.png",
    "ST-3": "0161_a_clean_minimalist_infographic_like_bar_chart_on.png",
    "ST-4": "0169_a_clean_polished_infographic_style_comparison_tw.png",
    "ST-7": "0322_a_wide_digital_illustration_in_the_same_violet_neo.png",
    "ST-8": "0279_a_sleek_glowing_neon_style_ui_illustration_on_a_d.png",
    "TL-4a": "0048_star-tl-4a.png",
    "TL-4b": "0049_star-tl-4b.png",
    "TL-4c": "0050_star-tl-4c.png",
    "TL-4d": "0051_star-tl-4d.png",
    "TL-4e": "0052_star-tl-4e.png",
    "TL-4f": "0053_star-tl-4f.png",
    "TL-4g": "0054_star-tl-4g.png",
    "TL-4h": "0055_star-tl-4h.png",
    "TL-7": "0041_TL-7.png",
    # replacements
    "IM-1": "0222_a_high_detail_glossy_cartoon_vector_style_illustr.png",
    "ER-5": "0348_png_illustration_a_cute_chibi_robot_mascot_in_gl.png",
    "SU-2a": "0239_a_long_exposure_astrophotography_scene_dramatic_s.png",
    "ST-9": "0057_ST-9.png",
}

sha = {}
for m in glob.glob(os.path.join(DUMP, "*", "MANIFEST.csv")):
    for r in csv.DictReader(open(m)):
        sha[r["archive_path"]] = r["sha256"]

slots = json.load(open(os.path.join(HERE, "slots.json")))["slots"]
maxpx = {}
for s in slots:
    m = round(4 * max(s.get("width") or 0, s.get("height") or 0))
    maxpx[s["source"]] = max(maxpx.get(s["source"], 0), m)

for mid, fn in sorted(TABLE.items()):
    found = glob.glob(os.path.join(DUMP, "*", "images", fn))
    assert len(found) == 1, (mid, fn, found)
    data = open(found[0], "rb").read()
    assert hashlib.sha256(data).hexdigest() == sha["images/" + fn], mid
    im = Image.open(found[0]); im.load()
    lim = maxpx[mid]
    if max(im.size) > lim:
        r = lim / max(im.size)
        im = im.resize((round(im.width * r), round(im.height * r)), Image.LANCZOS)
    im.save(os.path.join(OUT, mid + ".png"), optimize=True)
    print(mid, im.size, im.mode)
