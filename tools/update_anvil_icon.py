from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = Path(r"C:/Users/Dario Costa/Downloads/new_logo_anvil.png")
OUT = ROOT / "resources" / "icons"


def contain_square(img: Image.Image, size: int) -> Image.Image:
    img = img.convert("RGBA")
    work = img.copy()
    work.thumbnail((size, size), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(work, ((size - work.width) // 2, (size - work.height) // 2))
    return out


def paste_contained(dst: Image.Image, src: Image.Image, box: tuple[int, int, int, int]) -> None:
    x, y, w, h = box
    work = src.copy()
    work.thumbnail((w, h), Image.Resampling.LANCZOS)
    dst.alpha_composite(work, (x + (w - work.width) // 2, y + (h - work.height) // 2))


def main() -> None:
    img = Image.open(SRC).convert("RGBA")

    # Source artwork is already square; keep a full-resolution PNG for packaging/docs.
    img.save(OUT / "logo.png", optimize=True)

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    img.save(OUT / "icon.ico", sizes=[(s, s) for s in ico_sizes])

    # macOS icon. Pillow writes the standard ICNS representations from the source.
    img.save(OUT / "icon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])

    icon64 = contain_square(img, 64)
    data = icon64.tobytes("raw", "RGBA")
    lines = ["static unsigned char icon_rgba[] = {\n"]
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        lines.append("  " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
    lines.append("};\n")
    lines.append(f"static unsigned int icon_rgba_len = {len(data)};\n")
    (OUT / "icon.inl").write_text("".join(lines), newline="\r\n")

    # Pre-rendered packaging images whose SVG sources reference logo.png.
    # Keeping these in sync avoids stale branding when packaging tools use the raster assets directly.
    bg = (33, 37, 43, 255)
    blue = (55, 113, 200, 255)
    appdmg = Image.new("RGBA", (640, 480), bg)
    paste_contained(appdmg, img, (210, 38, 220, 223))
    from PIL import ImageDraw
    draw = ImageDraw.Draw(appdmg)
    draw.rounded_rectangle((132, 318, 238, 414), radius=12, fill=(230, 230, 230, 255))
    paste_contained(appdmg, img, (156, 337, 58, 58))
    draw.line((280, 366, 358, 366), fill=blue, width=10)
    draw.polygon([(374, 366), (344, 342), (344, 390)], fill=blue)
    draw.rounded_rectangle((402, 318, 508, 414), radius=12, fill=(230, 230, 230, 255))
    draw.polygon([(424, 348), (424, 396), (486, 396), (486, 348), (462, 348), (462, 330), (424, 330)], fill=(245,245,245,255), outline=(210,210,210,255))
    appdmg.save(ROOT / "resources" / "macos" / "appdmg.png", optimize=True)

    wiz = Image.new("RGBA", (164, 314), bg)
    paste_contained(wiz, img, (18, 28, 128, 130))
    draw = ImageDraw.Draw(wiz)
    draw.rounded_rectangle((54, 260, 110, 282), radius=5, outline=blue, width=4)
    draw.line((82, 220, 82, 252), fill=blue, width=7)
    draw.polygon([(82,260),(58,238),(70,238),(70,216),(94,216),(94,238),(106,238)], fill=blue)
    wiz.convert("RGBA").save(ROOT / "scripts" / "innosetup" / "wizard-modern-image.bmp")


if __name__ == "__main__":
    main()
