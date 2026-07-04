#!/usr/bin/env python3
"""Create 1280x640 GitHub social preview banner from app icon."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "assets" / "icon-1024.png"
OUT = ROOT / "assets" / "social-preview-1280x640.png"

W, H = 1280, 640
BG = (13, 17, 23)  # near GitHub dark
ACCENT = (35, 134, 54)
TEXT = (240, 246, 252)
SUB = (139, 148, 158)


def main():
    canvas = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(canvas)

    icon = Image.open(ICON).convert("RGBA")
    icon_size = 360
    icon = icon.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
    ix = 96
    iy = (H - icon_size) // 2
    canvas.paste(icon, (ix, iy), icon)

    title_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 64)
    sub_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 30)
    small_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 24)

    tx = ix + icon_size + 56
    draw.text((tx, 170), "Local AI Studio", font=title_font, fill=TEXT)
    draw.text((tx, 250), "Automated photoreal image gen & edit", font=sub_font, fill=ACCENT)
    draw.text((tx, 300), "for Apple Silicon Macs", font=sub_font, fill=TEXT)
    draw.text((tx, 380), "ComfyUI · Flux · SDXL · DiffusionBee · external SSD", font=small_font, fill=SUB)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUT, optimize=True)
    print(f"Wrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()