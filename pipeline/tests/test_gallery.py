from __future__ import annotations

import struct
import zlib
from pathlib import Path

from starpipe import gallery


def make_png(path: Path, width: int, height: int) -> None:
    """A real (blank) PNG of the given size."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    raw = b"".join(b"\x00" + b"\xff" * (width * 3) for _ in range(height))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        gallery.PNG_SIGNATURE
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def test_gallery_puts_clients_side_by_side_with_gaps(tmp_path: Path) -> None:
    make_png(tmp_path / "mac-gui" / "start.png", 8, 4)        # both sides, different pixel sizes (Retina)
    make_png(tmp_path / "desktop" / "start.png", 4, 2)
    make_png(tmp_path / "mac-gui" / "settings.png", 6, 6)     # the desktop has no settings screen
    make_png(tmp_path / "desktop" / "preferences.png", 5, 5)  # the gui has no preferences screen

    screens = gallery.collect(tmp_path)
    assert list(screens) == ["preferences", "settings", "start"]
    assert set(screens["start"]) == {"mac-gui", "desktop"}
    assert screens["start"]["mac-gui"].size_text == "8×4 px"
    assert screens["start"]["desktop"].size_text == "4×2 px"

    out = tmp_path / "index.html"
    assert gallery.main([str(tmp_path)]) == 0
    page = out.read_text(encoding="utf-8")

    # one row per screen, the gui before the desktop, images by relative path
    assert page.count("<tr id=") == 3
    start = page[page.index('<tr id="start"'):]
    start = start[: start.index("</tr>")]
    assert start.index("mac-gui/start.png") < start.index("desktop/start.png")
    assert f'width="{gallery.DISPLAY_WIDTH_PX}"' in start
    assert "8×4 px" in start and "4×2 px" in start

    # the screen the desktop lacks, and the one the gui lacks, are visible gaps on the right side
    settings = page[page.index('<tr id="settings"'):]
    settings = settings[: settings.index("</tr>")]
    assert "mac-gui/settings.png" in settings and "missing on desktop" in settings
    assert "desktop/settings.png" not in settings
    preferences = page[page.index('<tr id="preferences"'):]
    preferences = preferences[: preferences.index("</tr>")]
    assert "desktop/preferences.png" in preferences and "missing on mac-gui" in preferences
    assert page.count("missing on") == 2


def test_gallery_of_an_empty_folder_is_a_page_with_no_rows(tmp_path: Path) -> None:
    assert gallery.main([str(tmp_path), "--out", str(tmp_path / "x.html")]) == 0
    assert "<tr id=" not in (tmp_path / "x.html").read_text(encoding="utf-8")
