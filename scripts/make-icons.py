#!/usr/bin/env python3
"""Generate the CruX launcher icons from the brand source images.

Sources live in scripts/icon-src/ (transparent mark + dark backdrop). Outputs
are the HarmonyOS layered icon plus the square ability/start-window icons.

    pip3 install --user Pillow
    python3 scripts/make-icons.py
"""

import os

from PIL import Image, ImageChops, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "scripts", "icon-src")
APPSCOPE_MEDIA = os.path.join(REPO, "AppScope", "resources", "base", "media")
ENTRY_MEDIA = os.path.join(REPO, "entry", "src", "main", "resources", "base", "media")

LAYER_SIZE = 1024
ICON_SIZE = 216
STORE_SIZE = 512
MARK_RATIO = 0.84
CORNER_RATIO = 0.225
ALPHA_FLOOR = 16
EDGE_COVERAGE = 24
SPECK_CLEARANCE = 8


def square(image):
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def clean_mark(image):
    """Drop isolated alpha specks that would otherwise skew the framing."""
    alpha = image.getchannel("A")
    width, height = image.size
    pixels = alpha.load()
    columns = [0] * width
    rows = [0] * height
    for y in range(height):
        for x in range(width):
            if pixels[x, y] >= ALPHA_FLOOR:
                columns[x] += 1
                rows[y] += 1
    xs = [x for x in range(width) if columns[x] >= EDGE_COVERAGE]
    ys = [y for y in range(height) if rows[y] >= EDGE_COVERAGE]
    if not xs or not ys:
        raise SystemExit("front.png has no visible mark")
    keep = Image.new("L", image.size, 0)
    ImageDraw.Draw(keep).rectangle(
        (max(0, xs[0] - SPECK_CLEARANCE),
         max(0, ys[0] - SPECK_CLEARANCE),
         min(width - 1, xs[-1] + SPECK_CLEARANCE),
         min(height - 1, ys[-1] + SPECK_CLEARANCE)),
        fill=255,
    )
    alpha = ImageChops.multiply(alpha, keep)
    alpha = alpha.point(lambda value: 0 if value < ALPHA_FLOOR else value)
    cleaned = image.copy()
    cleaned.putalpha(alpha)
    return cleaned


def place_mark(logo, size, ratio):
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    target = int(size * ratio)
    scale = min(target / logo.width, target / logo.height)
    width = max(1, round(logo.width * scale))
    height = max(1, round(logo.height * scale))
    mark = logo.resize((width, height), Image.LANCZOS)
    canvas.alpha_composite(mark, ((size - width) // 2, (size - height) // 2))
    return canvas


def rounded_mask(size):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (size - 1, size - 1)],
        radius=int(size * CORNER_RATIO),
        fill=255,
    )
    return mask


def main():
    os.makedirs(APPSCOPE_MEDIA, exist_ok=True)
    os.makedirs(ENTRY_MEDIA, exist_ok=True)

    front = clean_mark(square(Image.open(os.path.join(SOURCE, "front.png")).convert("RGBA")))
    backdrop = square(Image.open(os.path.join(SOURCE, "backend.png")).convert("RGBA"))

    background = backdrop.resize((LAYER_SIZE, LAYER_SIZE), Image.LANCZOS)
    foreground = place_mark(front, LAYER_SIZE, MARK_RATIO)
    background.save(os.path.join(APPSCOPE_MEDIA, "background.png"))
    foreground.save(os.path.join(APPSCOPE_MEDIA, "foreground.png"))

    composite = background.copy()
    composite.alpha_composite(foreground)
    composite.putalpha(rounded_mask(LAYER_SIZE))
    for size in (ICON_SIZE, STORE_SIZE):
        icon = composite.resize((size, size), Image.LANCZOS)
        icon.save(os.path.join(APPSCOPE_MEDIA, "app_icon.png" if size == ICON_SIZE
                               else "app_icon_512.png"))
        if size == ICON_SIZE:
            icon.save(os.path.join(ENTRY_MEDIA, "app_icon.png"))

    print("wrote layered background/foreground plus app_icon.png (216, 512)")


if __name__ == "__main__":
    main()
