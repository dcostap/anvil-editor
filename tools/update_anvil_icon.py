from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "resources" / "icons"
DEFAULT_SRC = OUT / "logo-source.png"


def trim_alpha(img: Image.Image, threshold: int = 4) -> Image.Image:
    """Crop away fully transparent source padding without eating antialiasing."""
    img = img.convert("RGBA")
    alpha = img.getchannel("A")
    mask = alpha.point(lambda a: 255 if a > threshold else 0)
    bbox = mask.getbbox()
    return img.crop(bbox) if bbox else img


def contain_square(img: Image.Image, size: int) -> Image.Image:
    """Fit cropped artwork to a square without distortion or an added inset."""
    img = trim_alpha(img).convert("RGBA")
    work = img.copy()
    scale = size / max(work.size)
    work = work.resize((round(work.width * scale), round(work.height * scale)), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(work, ((size - work.width) // 2, (size - work.height) // 2))
    return out


def save_icon_inl(img: Image.Image) -> None:
    icon64 = contain_square(img, 64)
    data = icon64.tobytes("raw", "RGBA")
    lines = ["static unsigned char icon_rgba[] = {\n"]
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        lines.append("  " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
    lines.append("};\n")
    lines.append(f"static unsigned int icon_rgba_len = {len(data)};\n")
    (OUT / "icon.inl").write_text("".join(lines), newline="\r\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate Anvil product icon assets from source artwork.")
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SRC)
    args = parser.parse_args()

    with Image.open(args.source) as source:
        img = source.convert("RGBA")
    logo = contain_square(img, 1024)

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


if __name__ == "__main__":
    main()
