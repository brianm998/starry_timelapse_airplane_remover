#!/usr/bin/env python3
"""One-off: cut the HP-1 before/after pair from frame LRT_00092 of test_data/test_a7sii_10.

Recorded run (edit the values below if the rectangle moves):
  star commit : 7f5568ee (cli reported v0.12.6)
  command     : STAR_USE_GPU_FOR_MERGE=0 mason run --needs exclusive --exclusive -- cli/.build/release/star <WORK>/in --no-use-gpu
                (cli defaults: automatic clean, horizon detection on; run on a copy outside the repo
                 holding the 19 frames LRT_00080..98 as 16-bit LZW TIFF)
  rectangle   : x=2870 y=993 w=800 h=452 (the orange trail across the Milky Way)

Usage: make_real_crops.py <work dir> [--prepare | --crop]
  --prepare  convert the JPEGs to <work>/in/*.tif (then run the command above)
  --crop     cut art/masters/HP-1a.png (input, with streak) and HP-1b.png (star output, without)
"""
import glob, subprocess, sys
from pathlib import Path
from PIL import Image

RECT = (2870, 993, 800, 452)  # x, y, w, h
FRAME = "LRT_00092"
REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "test_data" / "test_a7sii_10"

def prepare(work: Path):
    (work / "in").mkdir(parents=True, exist_ok=True)
    for jpg in sorted(SRC.glob("LRT_*.jpg")):
        subprocess.run(["magick", str(jpg), "-depth", "16", "-compress", "lzw",
                        str(work / "in" / (jpg.stem + ".tif"))], check=True)

def crop(work: Path):
    x, y, w, h = RECT
    box = (x, y, x + w, y + h)
    outs = glob.glob(str(work / "in-star-v-*" / (FRAME + ".*")))
    assert len(outs) == 1, outs
    a = Image.open(work / "in" / (FRAME + ".tif"))
    b = Image.open(outs[0])
    assert a.size == b.size, (a.size, b.size)
    for im, name in ((a, "HP-1a"), (b, "HP-1b")):
        c = im.crop(box)
        if c.mode.startswith("I;16") or c.mode == "I":
            import numpy as np
            c = Image.fromarray((np.asarray(c).astype("float64") / 257).round().astype("uint8"))
        c.convert("RGB").save(REPO / "art" / "masters" / (name + ".png"))

if __name__ == "__main__":
    work = Path(sys.argv[1])
    {"--prepare": prepare, "--crop": crop}[sys.argv[2]](work)
