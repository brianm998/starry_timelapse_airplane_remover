#!/usr/bin/env python3
"""One-off: cut the HP-1 before/after pair from frame LRT_00092 of test_data/test_a7sii_10.

Recorded run (edit the values below if the rectangle moves):
  star commit : 7f5568ee (cli reported v0.12.6)
  command     : STAR_USE_GPU_FOR_MERGE=0 mason run --needs exclusive --exclusive -- cli/.build/release/star <WORK>/in --no-use-gpu
                (cli defaults: automatic clean, horizon detection on; run on a copy outside the repo
                 holding the 19 frames LRT_00080..98 as 16-bit LZW TIFF)
  rectangle   : x=2870 y=993 w=800 h=452 (the orange trail across the Milky Way)

HP-3 (t247): the same frame through the ten stages of the Detailed tab.
  star commit : 92729313 (cli reported v0.12.6), built with `swift build -c release` in cli/
  command     : STAR_USE_GPU_FOR_MERGE=0 mason run --needs exclusive --exclusive -- cli/.build/release/star <WORK>/in
                --no-use-gpu -c automatic:true -w -W --keep-temp-files
                (automatic-then-selective, so blobs, validation and outliers/ are written; same 19-frame copy)
  rectangle   : x=2880 y=1600 w=1320 h=550 (2.4:1: the faint trail above the right-hand ridge, and the ridge)
  sources, all from <WORK>/star_temp_in (frame 92 is index 12) unless noted:
    HP-3a horizon         mergedHorizon/ mask, shown as a tint over the original (the mask is 8-bit grey)
    HP-3b neighbors       the original LRT_00091 (a neighbor frame, unchanged)
    HP-3c aligned         LRT_00091 warped into frame 92 by its star homography from homography.db
                          (the default mode does not write aligned neighbors)
    HP-3d condensed       aligned/  (the median of all star-aligned neighbors, written for every frame)
    HP-3e subtraction     aligned-subtracted/ (gain-stretched with one fixed factor)
    HP-3f blobs           blobs-preview/ (preview size, scaled up to the rectangle, fixed gain 6)
    HP-3g blob processing the blobs after processing, drawn from outliers/12/outliers.bin (kept groups)
                          and dust.bin (discarded ones) over the dimmed frame; colour only
    HP-3h classification  each kept group coloured by the classifier's verdict from
                          outliers/12/OutlierGroupPaintData.json (positive = remove, red; else keep, green)
    HP-3i removal mask    validated-outlier-images/ (exactly the pixels identified; paintMask/ was not
                          written by this run)
    HP-3j final           auto-selective-processed/
  No text is drawn anywhere.

Usage: make_real_crops.py <work dir> [--prepare | --crop | --stages]
  --prepare  convert the JPEGs to <work>/in/*.tif (then run the command above)
  --crop     cut art/masters/HP-1a.png (input, with streak) and HP-1b.png (star output, without)
  --stages   cut art/masters/HP-3a..HP-3j.png after the HP-3 command above
"""
import glob, sqlite3, subprocess, sys
from pathlib import Path
from PIL import Image

RECT = (2870, 993, 800, 452)  # x, y, w, h
FRAME = "LRT_00092"
orig_size = (4240, 2832)
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

RECT3 = (2880, 1600, 1320, 550)

def stages(work: Path):
    import json
    import numpy as np
    t = work / "star_temp_in"
    idx = 12  # LRT_00092 is the 13th frame, LRT_00080 being index 0
    x0, y0, w, h = RECT3
    box = (x0, y0, x0 + w, y0 + h)
    out = REPO / "art" / "masters"

    def load(path):
        im = Image.open(path)
        if im.mode.startswith("I;16") or im.mode == "I":
            a = np.asarray(im).astype("float64") / 257
            return Image.fromarray(a.round().astype("uint8"))
        return im

    def rgb16(path):
        # PIL cannot read 16-bit RGB TIFF; ImageMagick makes an 8-bit copy of the rectangle
        tmp = work / "tmp_crop.png"
        subprocess.run(["magick", str(path), "-crop", "%dx%d+%d+%d" % (w, h, x0, y0), "+repage",
                        "-depth", "8", str(tmp)], check=True)
        return Image.open(tmp).convert("RGB")

    def save(im, name):
        assert im.size == (w, h), im.size
        im.convert("RGB").save(out / (name + ".png"))

    orig = rgb16(work / "in" / (FRAME + ".tif"))
    base = np.asarray(orig).astype("float64")

    # a: horizon, the mask as a tint
    mask = np.asarray(load(t / "mergedHorizon" / (FRAME + ".tif")).crop(box)).astype("float64") / 255
    tint = np.array([40, 90, 200], dtype="float64")
    ground = (1 - mask)[..., None]
    save(Image.fromarray((base * (1 - 0.55 * ground) + tint * 0.55 * ground).clip(0, 255).astype("uint8")), "HP-3a")

    # b: a neighbor
    nb = FRAME[:-2] + "91"
    save(rgb16(work / "in" / (nb + ".tif")), "HP-3b")

    # c: that neighbor, star-aligned into frame 92
    db = sqlite3.connect(work / "star_temp_in" / "homography.db")
    rec = json.loads(db.execute("select data from homographies where frame_index=? and type='star'", (idx,)).fetchone()[0])
    hom = next(n for n in rec["neighborHomography"] if n["frameIndex"] == idx - 1)["homography"]
    H = np.array(hom).reshape(3, 3)
    tmpfull = work / "tmp_full.png"
    subprocess.run(["magick", str(work / "in" / (nb + ".tif")), "-depth", "8", str(tmpfull)], check=True)
    src = Image.open(tmpfull).convert("RGB")
    T = np.array([[1, 0, x0], [0, 1, y0], [0, 0, 1]], dtype="float64")
    M = np.linalg.inv(H) @ T   # crop pixel -> frame 92 pixel -> neighbor pixel
    M = M / M[2, 2]
    warped = src.transform((w, h), Image.PERSPECTIVE, tuple(M.reshape(9)[:8]), Image.BICUBIC)
    save(warped, "HP-3c")

    # d: condensed
    save(rgb16(t / "aligned" / (FRAME + ".tif")), "HP-3d")

    # e: subtraction, one fixed gain
    sub = np.asarray(load(t / "aligned-subtracted" / (FRAME + ".tif")).crop(box)).astype("float64")
    save(Image.fromarray((sub * 4).clip(0, 255).astype("uint8")), "HP-3e")

    # f: blobs (a preview-size file, scaled up to the rectangle)
    prev = load(t / "blobs-preview" / (FRAME + ".tif.jpg"))
    sx = prev.size[0] / orig_size[0]
    pbox = tuple(round(v * sx) for v in box)
    bl = np.asarray(prev.crop(pbox).resize((w, h), Image.LANCZOS)).astype("float64")
    save(Image.fromarray((bl * 6).clip(0, 255).astype("uint8")), "HP-3f")  # fixed gain, as for e

    # g, h: groups drawn over the dimmed frame
    def groups(name):
        a = np.fromfile(t / "outliers" / str(idx) / name, dtype="<u2")
        n, i, res = int(a[0]), 1, {}
        for _ in range(n):
            bid, cnt = int(a[i]), int(a[i + 1])
            res[bid] = a[i + 2:i + 2 + 3 * cnt].reshape(-1, 3)[:, :2].astype(int)
            i += 2 + 3 * cnt
        return res
    kept, trash = groups("outliers.bin"), groups("dust.bin")
    verdict = {}
    pd = json.load(open(t / "outliers" / str(idx) / "OutlierGroupPaintData.json"))
    for k in range(0, len(pd), 2):
        verdict[pd[k]] = pd[k + 1]["fromClassifier"]["_0"] > 0

    def paint(colour_of):
        im = (base * 0.35).astype("float64")
        for gid, pts in list(trash.items()) + list(kept.items()):
            col = colour_of(gid, gid in kept)
            px, py = pts[:, 0] - x0, pts[:, 1] - y0
            ok = (px >= 0) & (px < w) & (py >= 0) & (py < h)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    xx, yy = (px + dx)[ok], (py + dy)[ok]
                    g = (xx >= 0) & (xx < w) & (yy >= 0) & (yy < h)
                    im[yy[g], xx[g]] = col
        return Image.fromarray(im.clip(0, 255).astype("uint8"))
    save(paint(lambda gid, k: (255, 170, 30) if k else (120, 120, 120)), "HP-3g")
    save(paint(lambda gid, k: ((235, 50, 50) if verdict.get(gid) else (60, 200, 90)) if k else (120, 120, 120)), "HP-3h")

    # i: removal mask
    save(load(t / "validated-outlier-images" / (FRAME + ".tif")).crop(box), "HP-3i")

    # j: final
    save(rgb16(t / "auto-selective-processed" / (FRAME + ".tif")), "HP-3j")

if __name__ == "__main__":
    work = Path(sys.argv[1])
    {"--prepare": prepare, "--crop": crop, "--stages": stages}[sys.argv[2]](work)
