#!/usr/bin/env python3
"""Generate OpenTwit-Web launcher icons.

HarmonyOS needs a *layered* app icon (background + foreground) in
AppScope/resources/base/media plus a square ability icon. The previous
placeholders were 1x1 transparent PNGs, which the launcher rendered as a
flat coloured square. This script draws real ones from scratch (no binary
assets checked in, no external image dependency beyond Pillow).

    pip3 install --user Pillow
    python3 scripts/make-icons.py
"""

import os

from PIL import Image, ImageDraw

SS = 4  # supersampling factor for anti-aliasing

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPSCOPE_MEDIA = os.path.join(REPO, "AppScope", "resources", "base", "media")
ENTRY_MEDIA = os.path.join(REPO, "entry", "src", "main", "resources", "base", "media")

LAYER_SIZE = 1024
ICON_SIZE = 216
MARK_RATIO = 0.52  # X glyph bounding box as a fraction of the canvas
BAR_RATIO = 0.115  # bar thickness as a fraction of the canvas


def gradient(size, top, bottom):
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / float(size - 1)
        color = tuple(int(round(top[i] + (bottom[i] - top[i]) * t)) for i in range(3))
        draw.line([(0, y), (size, y)], fill=color + (255,))
    return img


def draw_mark(img, size, color=(255, 255, 255, 255), inset=0.0):
    """Draw the crossing-bar mark centred on a transparent/solid canvas."""
    draw = ImageDraw.Draw(img)
    lo = (0.5 - MARK_RATIO / 2.0 + inset) * size
    hi = (0.5 + MARK_RATIO / 2.0 - inset) * size
    width = int(round(BAR_RATIO * size))
    radius = width / 2.0
    for a, b in (((lo, lo), (hi, hi)), ((hi, lo), (lo, hi))):
        draw.line([a, b], fill=color, width=width)
        for point in (a, b):
            draw.ellipse(
                [
                    point[0] - radius,
                    point[1] - radius,
                    point[0] + radius,
                    point[1] + radius,
                ],
                fill=color,
            )
    return img


def rounded_mask(size, radius_ratio=0.225):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (size - 1, size - 1)],
        radius=int(size * radius_ratio),
        fill=255,
    )
    return mask


def layered_background(size):
    return gradient(size, (10, 89, 247), (63, 182, 255))


def standalone_icon(size):
    canvas = layered_background(size)
    draw_mark(canvas, size)
    canvas.putalpha(rounded_mask(size))
    return canvas


def main():
    os.makedirs(APPSCOPE_MEDIA, exist_ok=True)
    os.makedirs(ENTRY_MEDIA, exist_ok=True)

    # Layered icon (system masks the background, foreground keeps a safe zone).
    background = layered_background(LAYER_SIZE * 1)
    foreground = Image.new("RGBA", (LAYER_SIZE, LAYER_SIZE), (0, 0, 0, 0))
    draw_mark(foreground, LAYER_SIZE, inset=0.06)
    background.save(os.path.join(APPSCOPE_MEDIA, "background.png"))
    foreground.save(os.path.join(APPSCOPE_MEDIA, "foreground.png"))

    # Square ability / start-window icon.
    standalone_icon(ICON_SIZE).save(os.path.join(APPSCOPE_MEDIA, "app_icon.png"))
    standalone_icon(ICON_SIZE).save(os.path.join(ENTRY_MEDIA, "app_icon.png"))

    # High-res fallback for store listings.
    standalone_icon(512).save(os.path.join(APPSCOPE_MEDIA, "app_icon_512.png"))

    print("wrote layered background/foreground plus app_icon.png (216, 512)")


if __name__ == "__main__":
    main()
