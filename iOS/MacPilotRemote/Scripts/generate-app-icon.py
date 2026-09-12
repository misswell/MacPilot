#!/usr/bin/env python3
"""Render the iOS app icon from the master artwork in Artwork/AppIconSource.png.

The master is a dark squircle with the cyan/violet mark on a padded canvas.
iOS applies its own continuous-corner mask and wants a full-bleed opaque
1024x1024 square, so the render keeps the mark at its original scale and paints
everything else with the squircle's own fill colour. Only the mark is copied
out of the master, which is why the source squircle's edge and the padding
around it cannot leak into the icon.

Run from anywhere:  python3 Scripts/generate-app-icon.py
Requires Pillow.
"""

from pathlib import Path

from PIL import Image

PROJECT = Path(__file__).resolve().parent.parent

SOURCE = PROJECT / "Artwork" / "AppIconSource.png"
DESTINATION = (
    PROJECT
    / "MacPilotRemote"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "AppIcon-1024.png"
)

CANVAS = 1024

# Centre of the source squircle on the 1254px master, measured from the art.
SOURCE_CENTER = (627, 626)

# Colour of the squircle interior, sampled away from the mark. Flat across the
# whole shape apart from a few pixels of edge shading.
FILL = (18, 27, 48)

# Distance from FILL, in summed RGB units, that counts as "not the mark". The
# padded background sits at most 37 away and the squircle's antialiased rim
# stays below that, while every mark pixel is 200+ away. The ramp keeps the
# mark's antialiased edge instead of cutting it off.
FLOOR = 45
CEILING = 80


def mark_alpha(source: Image.Image) -> Image.Image:
    """Return an 8-bit alpha mask that is opaque where the mark is drawn."""
    pixels = source.load()
    mask = Image.new("L", source.size)
    out = mask.load()
    width, height = source.size
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            distance = abs(r - FILL[0]) + abs(g - FILL[1]) + abs(b - FILL[2])
            if distance >= CEILING:
                out[x, y] = 255
            elif distance <= FLOOR:
                out[x, y] = 0
            else:
                out[x, y] = round((distance - FLOOR) * 255 / (CEILING - FLOOR))
    return mask


def render() -> None:
    master = Image.open(SOURCE).convert("RGB")

    icon = Image.new("RGB", (CANVAS, CANVAS), FILL)
    offset = (
        CANVAS // 2 - SOURCE_CENTER[0],
        CANVAS // 2 - SOURCE_CENTER[1],
    )
    icon.paste(master, offset, mark_alpha(master))

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    icon.save(DESTINATION)
    print(f"wrote {DESTINATION} ({icon.size[0]}x{icon.size[1]}, opaque)")


if __name__ == "__main__":
    render()
