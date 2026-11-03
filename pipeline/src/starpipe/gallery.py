"""The parity gallery: the macOS gui's screenshots and the desktop client's, side by side in one HTML page.

``I save a screenshot named "<name>"`` (gherkin/steps.json) makes each runner write ``<dir>/<client>/<name>.png``;
this puts the two folders in one page, a row per screen, the gui left and the desktop right, both at the same
display width with their pixel sizes printed, so a difference in layout, size, font or colour is visible. A
screen one client has not saved is a visible gap, not a missing row. Advisory only: nothing here fails on a
difference. Developer tooling (stdlib only); ``gherkin/ui/gallery.sh`` runs it.

    python -m starpipe.gallery <dir> [--out index.html]
"""

from __future__ import annotations

import argparse
import html
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

CLIENTS: tuple[str, str] = ("mac-gui", "desktop")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# both images are shown this wide, whatever their pixels: a Retina capture is twice the pixels of the same window
DISPLAY_WIDTH_PX = 700


@dataclass(frozen=True)
class Shot:
    """One saved screenshot."""

    path: Path
    width: int
    height: int

    @property
    def size_text(self) -> str:
        return f"{self.width}×{self.height} px"


def png_size(path: Path) -> tuple[int, int]:
    """The pixel size from the IHDR chunk; (0, 0) for a file that is not a PNG."""
    with path.open("rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        return (0, 0)
    width, height = struct.unpack(">II", head[16:24])
    return (width, height)


def collect(directory: Path) -> dict[str, dict[str, Shot]]:
    """Screen name -> client -> screenshot, for every ``<directory>/<client>/<name>.png``."""
    screens: dict[str, dict[str, Shot]] = {}
    for client in CLIENTS:
        folder = directory / client
        if not folder.is_dir():
            continue
        for png in sorted(folder.glob("*.png")):
            w, h = png_size(png)
            screens.setdefault(png.stem, {})[client] = Shot(png, w, h)
    return dict(sorted(screens.items()))


def _cell(client: str, shot: Shot | None, base: Path) -> str:
    if shot is None:
        return (
            f'<td class="gap" data-client="{client}"><div class="gapbox">'
            f"missing on {html.escape(client)}</div></td>"
        )
    rel = html.escape(shot.path.relative_to(base).as_posix(), quote=True)
    return (
        f'<td data-client="{client}"><a href="{rel}"><img src="{rel}" width="{DISPLAY_WIDTH_PX}"'
        f' alt="{html.escape(client)}"></a><div class="size">{html.escape(shot.size_text)}</div></td>'
    )


def render(directory: Path, out: Path | None = None) -> str:
    """The page for the screenshots under ``directory``; image paths are relative to where the page is written."""
    base = (out.parent if out is not None else directory).resolve()
    screens = collect(directory.resolve())
    rows: list[str] = []
    for name, shots in screens.items():
        cells = "".join(_cell(client, shots.get(client), base) for client in CLIENTS)
        rows.append(f'<tr id="{html.escape(name, quote=True)}"><th>{html.escape(name)}</th>{cells}</tr>')
    missing = sum(1 for shots in screens.values() for c in CLIENTS if c not in shots)
    heads = "".join(f"<th>{html.escape(c)}</th>" for c in CLIENTS)
    return (
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>star parity gallery</title>\n"
        "<style>body{font-family:-apple-system,sans-serif;margin:1em}table{border-collapse:collapse}"
        "th,td{border:1px solid #bbb;padding:6px;vertical-align:top}img{display:block;border:1px solid #888}"
        ".size{font-size:12px;color:#555;margin-top:2px}.gap{background:#fdeaea}"
        ".gapbox{width:700px;height:120px;display:flex;align-items:center;justify-content:center;color:#a00}"
        "</style></head><body>\n"
        f"<h1>star parity gallery</h1><p>{len(screens)} screens, {missing} gaps (a screen one client has not saved). "
        f"Both clients are shown {DISPLAY_WIDTH_PX}px wide; the pixel size under each image is its own.</p>\n"
        f"<table><tr><th>screen</th>{heads}</tr>\n" + "\n".join(rows) + "\n</table></body></html>\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="starpipe.gallery", description="Put the gui and desktop gallery screenshots side by side in one HTML page.")
    parser.add_argument("directory", type=Path, help="a gallery folder holding mac-gui/ and desktop/")
    parser.add_argument("--out", type=Path, default=None, help="the page to write (default <directory>/index.html)")
    ns = parser.parse_args(argv)
    directory: Path = ns.directory
    if not directory.is_dir():
        print(f"{directory} is not a directory", file=sys.stderr)
        return 2
    out: Path = ns.out if ns.out is not None else directory / "index.html"
    out.write_text(render(directory, out), encoding="utf-8")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
