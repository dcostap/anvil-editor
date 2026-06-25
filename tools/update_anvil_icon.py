from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = Path(r"C:/Users/Darius/Downloads/logo.png")
OUT = ROOT / "resources" / "icons"


def trim_alpha(img: Image.Image, threshold: int = 4) -> Image.Image:
    """Crop away fully transparent source padding without eating antialiasing."""
    img = img.convert("RGBA")
    alpha = img.getchannel("A")
    mask = alpha.point(lambda a: 255 if a > threshold else 0)
    bbox = mask.getbbox()
    return img.crop(bbox) if bbox else img


def contain_square(img: Image.Image, size: int, padding: float = 0.08) -> Image.Image:
    """Return a square transparent icon with the source preserved and centered."""
    img = trim_alpha(img).convert("RGBA")
    target = max(1, round(size * (1.0 - padding * 2.0)))
    work = img.copy()
    work.thumbnail((target, target), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(work, ((size - work.width) // 2, (size - work.height) // 2))
    return out


def paste_contained(dst: Image.Image, src: Image.Image, box: tuple[int, int, int, int]) -> None:
    x, y, w, h = box
    work = trim_alpha(src).copy()
    work.thumbnail((w, h), Image.Resampling.LANCZOS)
    dst.alpha_composite(work, (x + (w - work.width) // 2, y + (h - work.height) // 2))


def save_icon_inl(img: Image.Image) -> None:
    icon64 = contain_square(img, 64, padding=0.05)
    data = icon64.tobytes("raw", "RGBA")
    lines = ["static unsigned char icon_rgba[] = {\n"]
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        lines.append("  " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
    lines.append("};\n")
    lines.append(f"static unsigned int icon_rgba_len = {len(data)};\n")
    (OUT / "icon.inl").write_text("".join(lines), newline="\r\n")


def save_packaging_images(img: Image.Image) -> None:
    # Pre-rendered packaging images whose SVG sources reference logo.png.
    # Keeping these in sync avoids stale branding when packaging tools use the raster assets directly.
    bg = (33, 37, 43, 255)
    blue = (55, 113, 200, 255)

    appdmg = Image.new("RGBA", (640, 480), bg)
    paste_contained(appdmg, img, (210, 38, 220, 223))
    draw = ImageDraw.Draw(appdmg)
    draw.rounded_rectangle((132, 318, 238, 414), radius=12, fill=(230, 230, 230, 255))
    paste_contained(appdmg, img, (156, 337, 58, 58))
    draw.line((280, 366, 358, 366), fill=blue, width=10)
    draw.polygon([(374, 366), (344, 342), (344, 390)], fill=blue)
    draw.rounded_rectangle((402, 318, 508, 414), radius=12, fill=(230, 230, 230, 255))
    draw.polygon(
        [(424, 348), (424, 396), (486, 396), (486, 348), (462, 348), (462, 330), (424, 330)],
        fill=(245, 245, 245, 255),
        outline=(210, 210, 210, 255),
    )
    appdmg.save(ROOT / "resources" / "macos" / "appdmg.png", optimize=True)

    wiz = Image.new("RGBA", (164, 314), bg)
    paste_contained(wiz, img, (18, 28, 128, 130))
    draw = ImageDraw.Draw(wiz)
    draw.rounded_rectangle((54, 260, 110, 282), radius=5, outline=blue, width=4)
    draw.line((82, 220, 82, 252), fill=blue, width=7)
    draw.polygon([(82, 260), (58, 238), (70, 238), (70, 216), (94, 216), (94, 238), (106, 238)], fill=blue)
    wiz.convert("RGB").save(ROOT / "scripts" / "innosetup" / "wizard-modern-image.bmp")

    small = Image.new("RGBA", (55, 55), (255, 255, 255, 255))
    paste_contained(small, img, (2, 2, 51, 51))
    small.convert("RGB").save(ROOT / "scripts" / "innosetup" / "anvil-55px.bmp")


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate Anvil product icon assets from source artwork.")
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SRC)
    args = parser.parse_args()

    img = Image.open(args.source).convert("RGBA")
    logo = contain_square(img, 1024, padding=0.05)

    OUT.mkdir(parents=True, exist_ok=True)
    logo.save(OUT / "logo.png", optimize=True)

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    logo.save(OUT / "icon.ico", sizes=[(s, s) for s in ico_sizes])

    # macOS icon. Pillow writes the standard ICNS representations from the source.
    logo.save(
        OUT / "icon.icns",
        sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
    )

    save_icon_inl(img)
    save_packaging_images(img)


if __name__ == "__main__":
    main()
