#!/usr/bin/env python3
"""Renders the App Store screenshot sets from iphone.html and mac.html.

    python3 Tools/AppStoreScreenshots/render.py [iphone|mac ...]

Reads the raw captures in build/raw2 and build/raw3 (see capture.sh) and writes flattened RGB
PNGs, one per frame, to build/app-store/{iphone,mac}, ready to upload, plus the whole set
side by side as build/app-store/{iphone,mac}-overview.png. Needs Playwright with Chromium:
pip install playwright && playwright install chromium.

The iPhone pages are laid out at the 6.9" size, 1320 x 2868, and each frame is also scaled
to the 6.5" size, 1284 x 2778, into build/app-store/iphone-6.5. The two are not quite the
same shape, so those frames are scaled to width and then trimmed by six pixels top and bottom.
"""

import io
import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "build" / "app-store"

SETS = {
    "iphone": {"page": "iphone.html", "size": (1320, 2868), "frames": 9,
               "export": ("iphone-6.5", (1284, 2778))},
    "mac": {"page": "mac.html", "size": (2880, 1800), "frames": 10},
}

def render(browser, name):
    spec = SETS[name]
    width, height = spec["size"]
    count = spec["frames"]
    page = browser.new_page(viewport={"width": width * count, "height": height}, device_scale_factor=1)
    page.goto((HERE / spec["page"]).as_uri())
    page.wait_for_selector("body[data-ready='1']")
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(400)

    out = OUT / name
    out.mkdir(parents=True, exist_ok=True)
    # Clear the last render's frames, so a set that loses a frame doesn't leave a stale one.
    for folder in [out] + ([OUT / spec["export"][0]] if "export" in spec else []):
        for old in folder.glob(f"{name}-*.png"):
            old.unlink()
    strip = Image.open(io.BytesIO(page.screenshot(full_page=False))).convert("RGB")
    strip.save(OUT / f"{name}-overview.png")
    for index in range(count):
        tile = strip.crop((index * width, 0, (index + 1) * width, height))
        path = out / f"{name}-{index + 1}.png"
        tile.save(path)
        print(f"  {path.relative_to(ROOT)}  {tile.size[0]} x {tile.size[1]}")
        if "export" in spec:
            folder, size = spec["export"]
            (OUT / folder).mkdir(parents=True, exist_ok=True)
            resize(tile, *size).save(OUT / folder / f"{name}-{index + 1}.png")
    page.close()


def resize(tile, width, height):
    """Scales a frame to width, then trims the leftover height evenly top and bottom."""
    scaled = tile.resize((width, round(tile.height * width / tile.width)), Image.LANCZOS)
    top = (scaled.height - height) // 2
    return scaled.crop((0, top, width, top + height))


def launch(p):
    args = ["--allow-file-access-from-files", "--force-color-profile=srgb"]
    try:
        return p.chromium.launch(args=args)
    except Exception:
        # The Python package pins one Chromium build; any cached Playwright build renders
        # these pages the same, so use the newest one rather than downloading another.
        cache = Path.home() / "Library" / "Caches" / "ms-playwright"
        shells = sorted(cache.glob("chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"))
        if not shells:
            raise
        return p.chromium.launch(executable_path=str(shells[-1]), args=args)


def main():
    names = sys.argv[1:] or list(SETS)
    with sync_playwright() as p:
        browser = launch(p)
        for name in names:
            print(name)
            render(browser, name)
        browser.close()


if __name__ == "__main__":
    main()
