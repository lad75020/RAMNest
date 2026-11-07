#!/usr/bin/env python3
"""Regenerate RAMNest's macOS AppIcon assets (requires ImageMagick 7)."""

import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "resources/IconSource/RAMNest-generated.png"
MASTER = ROOT / "resources/IconSource/RAMNest-1024.png"
CATALOG = ROOT / "resources/Assets.xcassets"
ICONSET = CATALOG / "AppIcon.appiconset"


def main():
    magick = shutil.which("magick")
    if not magick:
        raise SystemExit("ImageMagick 7 is required: brew install imagemagick")
    ICONSET.mkdir(parents=True, exist_ok=True)
    # Flood only the connected white canvas; the chip's highlights stay intact.
    # Transparent padding and an 864 px tile align with native macOS icon sizing.
    subprocess.run([
        magick, str(SOURCE), "-alpha", "on", "-fuzz", "20%",
        "-fill", "none", "-draw", "alpha 0,0 floodfill",
        "-channel", "A", "-morphology", "Erode", "Disk:1", "-blur", "0x0.5", "+channel",
        "-trim", "+repage",
        "-resize", "864x864", "-background", "none", "-gravity", "center",
        "-extent", "1024x1024", "-colorspace", "sRGB", "PNG32:" + str(MASTER),
    ], check=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            filename = f"icon_{size}x{size}{suffix}.png"
            pixels = size * scale
            subprocess.run([
                magick, str(MASTER), "-filter", "Lanczos", "-resize",
                f"{pixels}x{pixels}", "-strip", "PNG32:" + str(ICONSET / filename),
            ], check=True)
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
    info = {"author": "xcode", "version": 1}
    (CATALOG / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
    (ICONSET / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
    print(f"Generated {len(images)} macOS AppIcon slots in {ICONSET}")
    print(f"Master: {MASTER}")


if __name__ == "__main__":
    main()
