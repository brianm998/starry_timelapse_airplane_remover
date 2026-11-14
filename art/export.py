#!/usr/bin/env python3
"""Clean, size and write every client art asset from art/masters + art/slots.json.

Writes (all deterministic, so a second run changes nothing):
  gui/Assets.xcassets/<slot>.imageset/{Contents.json,<slot>1x.<ext>,<slot>2x.<ext>}
  star-desktop/src/main/resources/art/<slot>.<ext>        (the 2x image)
  gui/star/StarArt.swift
  star-desktop/src/main/kotlin/com/star/desktop/ui/components/StarArt.kt

  gui/star/Assets.xcassets/AppIcon.appiconset/icon_*.png   (BR-2 below 128 px, BR-1 from 128 px)
  star-desktop/packaging/{star.icns,star.ico,star.png}      (same split; star.png is BR-1 at 512)

  python3 art/export.py            write everything
  python3 art/export.py --check    write nothing; exit 1 if any output would change
  python3 art/export.py --sheet P  also write a contact sheet of every slot on #050A17 to P
"""
import io, json, os, shutil, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")
CATALOG = os.path.join(ROOT, "gui", "Assets.xcassets")
DESKTOP_RES = os.path.join(ROOT, "star-desktop", "src", "main", "resources", "art")
SWIFT_OUT = os.path.join(ROOT, "gui", "star", "StarArt.swift")
KOTLIN_OUT = os.path.join(ROOT, "star-desktop", "src", "main", "kotlin", "com", "star", "desktop", "ui", "components", "StarArt.kt")

# Defaults, overridable per slot in slots.json ("tolerance", "spread", "erode", "snap", "snap_opaque").
CHECKER_TOLERANCE = 0.20   # a checker tone this far below white (and neutral) still counts as background
NEUTRAL_SPREAD = 0.08      # max-min channel spread for "neutral grey"
BLACK_TOLERANCE = 0.16     # tile corners: pixels this close to black
JPEG_QUALITY = 85


def flood_from_border(cand):
    """Boolean mask of candidate pixels connected (4-way) to the image border."""
    from collections import deque
    h, w = cand.shape
    c = cand.ravel().tolist()
    seen = bytearray(h * w)
    q = deque()
    def push(i):
        if c[i] and not seen[i]:
            seen[i] = 1
            q.append(i)
    for x in range(w):
        push(x); push((h - 1) * w + x)
    for y in range(h):
        push(y * w); push(y * w + w - 1)
    while q:
        i = q.popleft()
        x = i % w
        if x > 0: push(i - 1)
        if x < w - 1: push(i + 1)
        if i >= w: push(i - w)
        if i < (h - 1) * w: push(i + w)
    return np.frombuffer(bytes(seen), np.uint8).reshape(h, w) == 1


def erode(alpha, px):
    im = Image.fromarray(alpha, "L")
    for _ in range(px):
        im = im.filter(ImageFilter.MinFilter(3))
    return np.asarray(im)


def decontaminate(rgb, alpha):
    """Replace the colour of edge pixels with the mean colour of solid pixels nearby."""
    solid = erode(alpha, 2) > 250
    wgt = solid.astype(np.float32)
    out = rgb.astype(np.float32)
    # mean of the solid neighbours via an integral image
    def boxsum(a, r):
        k = 2 * r + 1
        p = np.pad(a, ((r + 1, r), (r + 1, r)) + ((0, 0),) * (a.ndim - 2))
        c = p.cumsum(0).cumsum(1)
        return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]
    s = boxsum(wgt, 3)
    m = np.stack([boxsum(out[..., c] * wgt, 3) for c in range(3)], -1)
    fill = np.where(s[..., None] > 0, m / np.maximum(s[..., None], 1), out)
    edge = (alpha > 0) & ~solid & (s > 0)
    out[edge] = fill[edge]
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


def matte(im, how, slot):
    """RGB(A) image -> RGBA with the painted background removed."""
    rgb = np.asarray(im.convert("RGB")).astype(np.int16)
    if how == "checker":
        tol = slot.get("tolerance", CHECKER_TOLERANCE)
        spread = rgb.max(-1) - rgb.min(-1)
        cand = (rgb.min(-1) >= 255 * (1 - tol)) & (spread <= 255 * slot.get("spread", NEUTRAL_SPREAD))
    else:  # black corners
        tol = slot.get("tolerance", BLACK_TOLERANCE)
        cand = rgb.max(-1) <= 255 * tol
    bg = flood_from_border(cand)
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    alpha = erode(alpha, slot.get("erode", 1))
    # soften the hard edge a little so it does not look cut with scissors
    alpha = np.asarray(Image.fromarray(alpha, "L").filter(ImageFilter.GaussianBlur(0.6)))
    alpha = np.where(erode(alpha, 1) == 0, np.minimum(alpha, 255), alpha)
    clean = decontaminate(rgb.astype(np.uint8), alpha)
    return Image.fromarray(np.dstack([clean, alpha]), "RGBA")


def has_real_alpha(im):
    if im.mode != "RGBA":
        return False
    a = np.asarray(im.getchannel("A"))
    h, w = a.shape
    corners = [a[0, 0], a[0, w - 1], a[h - 1, 0], a[h - 1, w - 1]]
    return min(corners) < 16


def trim(im):
    a = np.asarray(im.getchannel("A"))
    ys, xs = np.nonzero(a > 8)
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def crop_ratio(im, ratio, anchor):
    rw, rh = (int(v) for v in ratio.split(":"))
    w, h = im.size
    if w * rh > h * rw:      # too wide: cut width
        nw = round(h * rw / rh)
        x = round((w - nw) * anchor[0])
        return im.crop((x, 0, x + nw, h))
    nh = round(w * rh / rw)
    y = round((h - nh) * anchor[1])
    return im.crop((0, y, w, y + nh))


def snap_alpha(im, slot):
    """Optional per-slot "snap": after sizing, clear edge alpha below snap and make alpha above
    "snap_opaque" (default 255 - snap) opaque, so no faint near-white rim survives resampling."""
    snap = slot.get("snap")
    if not snap:
        return im
    keep = slot.get("snap_opaque", 255 - snap)
    a = np.asarray(im.getchannel("A"))
    a = np.where(a >= keep, 255, np.where(a < snap, 0, a)).astype(np.uint8)
    out = im.copy()
    out.putalpha(Image.fromarray(a, "L"))
    return out


def process(slot):
    """-> (im1x, im2x, ext, cleaned)"""
    kind = slot["kind"]
    im = Image.open(os.path.join(ART, "masters", slot["source"] + ".png"))
    im.load()
    cleaned = False
    if kind == "scene":
        im = im.convert("RGB")           # SU-2a's uniform 0.94 alpha is ignored on purpose
        if "crop" in slot:
            im = crop_ratio(im, slot["crop"], slot.get("anchor", [0.5, 0.5]))
    else:
        if not has_real_alpha(im):
            im = matte(im, "black" if kind == "tile" else "checker", slot)
            cleaned = True
        else:
            im = im.convert("RGBA")
        im = trim(im)
    bw, bh = slot.get("width"), slot.get("height")
    iw, ih = im.size
    scale = min([b / d for b, d in ((bw, iw), (bh, ih)) if b])
    s2 = min(2 * scale, 1.0)             # never upscale
    s1 = min(scale, s2)
    def sized(s):
        out = im if s == 1.0 else im.resize((max(1, round(iw * s)), max(1, round(ih * s))), Image.LANCZOS)
        return snap_alpha(out, slot) if kind != "scene" else out
    return sized(s1), sized(s2), ("jpg" if kind == "scene" else "png"), cleaned


def encode(im, ext):
    b = io.BytesIO()
    if ext == "jpg":
        im.convert("RGB").save(b, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=False)
    else:
        im.save(b, "PNG", optimize=True)
    return b.getvalue()


SWIFT_KEYWORDS = {"import", "default", "internal", "public", "private", "static", "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "in", "is", "as"}


def camel(name):
    parts = name.split("_")[1:]
    c = parts[0] + "".join(p.capitalize() for p in parts[1:])
    return f"`{c}`" if c in SWIFT_KEYWORDS else c


def contents_json(slot, ext):
    n = slot["name"]
    return json.dumps({
        "images": [{"filename": f"{n}{s}.{ext}", "idiom": "universal", "scale": s} for s in ("1x", "2x")],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n"


def swift_src(rows):
    cases = "\n".join(f'    case {camel(r["name"])} = "{r["name"]}"' for r in rows)
    sizes = "\n".join(f'        case .{camel(r["name"])}: return CGSize(width: {r["w"]}, height: {r["h"]})' for r in rows)
    kinds = "\n".join(f'        case .{camel(r["name"])}: return .{r["kind"]}' for r in rows)
    return f'''// GENERATED by art/export.py from art/slots.json. Do not edit; run `python3 art/export.py`.
import SwiftUI

/// One piece of artwork. Each case names an imageset in the app's asset catalog.
enum StarArt: String, CaseIterable {{
{cases}

    enum Kind {{ case cutout, tile, scene }}

    var kind: Kind {{
        switch self {{
{kinds}
        }}
    }}

    /// Display size in points (the 1x image size).
    var size: CGSize {{
        switch self {{
{sizes}
        }}
    }}
}}

/// Draws a piece of artwork at its display size. Art is decoration: it adds no strings and is hidden from accessibility.
struct ArtImage: View {{
    let art: StarArt
    /// When set, the picture is scaled (aspect kept) so its longer side is this many points.
    let side: CGFloat?

    init(_ art: StarArt, fitting side: CGFloat? = nil) {{
        self.art = art
        self.side = side
    }}

    /// The size the picture is drawn at.
    var displaySize: CGSize {{
        guard let side else {{ return art.size }}
        let scale = side / max(art.size.width, art.size.height)
        return CGSize(width: (art.size.width * scale).rounded(), height: (art.size.height * scale).rounded())
    }}

    var body: some View {{
        Image(art.rawValue)
            .resizable()
            .interpolation(.high)
            .frame(width: displaySize.width, height: displaySize.height)
            .accessibilityHidden(true)
    }}
}}
'''


def kotlin_src(rows):
    ents = ",\n".join(f'    {r["name"].upper()}("{r["name"]}", "{r["file"]}", ArtKind.{r["kind"].upper()}, {r["w"]}, {r["h"]})' for r in rows)
    return f'''// GENERATED by art/export.py from art/slots.json. Do not edit; run `python3 art/export.py`.
package com.star.desktop.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

enum class ArtKind {{ CUTOUT, TILE, SCENE }}

/** One piece of artwork, loaded from `resources/art/<file>`. [width] and [height] are the display size in dp. */
enum class StarArt(val slot: String, val file: String, val kind: ArtKind, val width: Int, val height: Int) {{
{ents};

    val resourcePath: String get() = "art/$file"
}}

/** Draws a piece of artwork at its display size (or fitted to [fitting]). Art is decoration: it adds no strings (no content description). */
@Composable
fun ArtImage(art: StarArt, modifier: Modifier = Modifier, fitting: Int? = null) {{
    val (w, h) = art.fittedSize(fitting)
    Image(
        painter = painterResource(art.resourcePath),
        contentDescription = null,
        modifier = modifier.size(w.dp, h.dp),
    )
}}

/** The display size in dp; with [side] the longer side is scaled to it and the aspect is kept. */
fun StarArt.fittedSize(side: Int?): Pair<Int, Int> {{
    if (side == null) return width to height
    val scale = side.toDouble() / maxOf(width, height)
    return Math.round(width * scale).toInt() to Math.round(height * scale).toInt()
}}
'''


APPICON = os.path.join(ROOT, "gui", "star", "Assets.xcassets", "AppIcon.appiconset")
PACKAGING = os.path.join(ROOT, "star-desktop", "packaging")
APPICON_SLOTS = {"16x16": 16, "16x16@2x": 32, "32x32": 32, "32x32@2x": 64, "128x128": 128, "128x128@2x": 256,
                 "256x256": 256, "256x256@2x": 512, "512x512": 512, "512x512@2x": 1024}
ICON_SPLIT = 128   # below this the simplified BR-2 is used, from here up BR-1


def icon_body(name):
    """The master's body only: alpha < 128 is cleared (stray specks) and the canvas trimmed to the rest."""
    im = Image.open(os.path.join(ART, "masters", name + ".png")).convert("RGBA")
    a = np.asarray(im)[..., 3]
    ys, xs = np.where(a >= 128)
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    arr = np.array(im)
    keep = np.zeros(a.shape, bool)
    keep[box[1]:box[3], box[0]:box[2]] = True
    arr[~keep] = 0
    return Image.fromarray(arr, "RGBA").crop(box)


def icon_png(body, size, fill=824 / 1024):
    w = round(size * fill)
    h = max(1, round(body.height * w / body.width))
    r = body.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(r, ((size - w) // 2, (size - h) // 2))
    return encode(canvas, "png")


def icon_files():
    bodies = {"BR-1": icon_body("BR-1"), "BR-2": icon_body("BR-2")}
    def png(size, fill=824 / 1024):
        return icon_png(bodies["BR-2" if size < ICON_SPLIT else "BR-1"], size, fill)
    files = {}
    for slot, px in APPICON_SLOTS.items():
        files[os.path.join(APPICON, f"icon_{slot}.png")] = png(px)
    # icns: 'icns' + length, then (type, length, PNG) chunks
    chunks = b""
    for typ, px in (("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256), ("ic08", 256),
                    ("ic14", 512), ("ic09", 512), ("ic10", 1024)):
        d = png(px)
        chunks += typ.encode() + (8 + len(d)).to_bytes(4, "big") + d
    files[os.path.join(PACKAGING, "star.icns")] = b"icns" + (8 + len(chunks)).to_bytes(4, "big") + chunks
    # ico: ICONDIR + entries, PNG payloads
    sizes = (16, 24, 32, 48, 64, 128, 256)
    datas = [png(px) for px in sizes]
    head = (0).to_bytes(2, "little") + (1).to_bytes(2, "little") + len(sizes).to_bytes(2, "little")
    off = 6 + 16 * len(sizes)
    ents = b""
    for px, d in zip(sizes, datas):
        b = 0 if px >= 256 else px
        ents += bytes([b, b, 0, 0]) + (1).to_bytes(2, "little") + (32).to_bytes(2, "little") \
            + len(d).to_bytes(4, "little") + off.to_bytes(4, "little")
        off += len(d)
    files[os.path.join(PACKAGING, "star.ico")] = head + ents + b"".join(datas)
    files[os.path.join(PACKAGING, "star.png")] = icon_png(bodies["BR-1"], 512, 0.94)
    return files


def build():
    slots = json.load(open(os.path.join(ART, "slots.json")))["slots"]
    files, rows, images = {}, [], {}
    for slot in slots:
        im1, im2, ext, cleaned = process(slot)
        n = slot["name"]
        d = os.path.join(CATALOG, n + ".imageset")
        files[os.path.join(d, "Contents.json")] = contents_json(slot, ext).encode()
        files[os.path.join(d, f"{n}1x.{ext}")] = encode(im1, ext)
        files[os.path.join(d, f"{n}2x.{ext}")] = encode(im2, ext)
        files[os.path.join(DESKTOP_RES, f"{n}.{ext}")] = files[os.path.join(d, f"{n}2x.{ext}")]
        rows.append({"name": n, "file": f"{n}.{ext}", "kind": slot["kind"], "w": im1.width, "h": im1.height})
        images[n] = (im1, slot, cleaned)
    files.update(icon_files())
    files[SWIFT_OUT] = swift_src(rows).encode()
    files[KOTLIN_OUT] = kotlin_src(rows).encode()
    return files, images


def stale_dirs(files):
    """Imageset dirs and art resources that no slot owns any more."""
    want = set(files)
    gone = []
    for n in os.listdir(CATALOG):
        if n.startswith("art_") and n.endswith(".imageset"):
            d = os.path.join(CATALOG, n)
            gone += [os.path.join(d, f) for f in os.listdir(d) if os.path.join(d, f) not in want]
    if os.path.isdir(DESKTOP_RES):
        gone += [os.path.join(DESKTOP_RES, f) for f in os.listdir(DESKTOP_RES) if os.path.join(DESKTOP_RES, f) not in want]
    return gone


def contact_sheet(images, path):
    cell, pad = 300, 12
    cols = 6
    rows = (len(images) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * cell), (5, 10, 23))
    for i, (n, (im, slot, cleaned)) in enumerate(images.items()):
        t = im.convert("RGBA")
        t.thumbnail((cell - 2 * pad, cell - 2 * pad))
        x, y = (i % cols) * cell + pad, (i // cols) * cell + pad
        sheet.paste(t, (x, y), t)
        ImageDraw.Draw(sheet).text((x, y + cell - 2 * pad - 4), n, fill=(200, 200, 200))
    sheet.save(path)


def main(argv):
    check = "--check" in argv
    files, images = build()
    if "--sheet" in argv:
        contact_sheet(images, argv[argv.index("--sheet") + 1])
    changed = []
    for p, data in files.items():
        if not os.path.exists(p) or open(p, "rb").read() != data:
            changed.append(p)
    stale = stale_dirs(files)
    if check:
        for p in changed + stale:
            print("would change:", os.path.relpath(p, ROOT))
        return 1 if changed or stale else 0
    for p in stale:
        os.remove(p)
    for p in changed:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(files[p])
    print(f"{len(changed)} files written, {len(files) - len(changed)} unchanged, {len(stale)} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
