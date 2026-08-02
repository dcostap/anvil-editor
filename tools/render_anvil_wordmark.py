"""Render an alternative ``anvil`` wordmark using the reconstructed glyph style.

The existing reconstructed mark is reused as the first lowercase ``a``.  The
remaining letters are deliberately angular block glyphs with the same visual
recipe: black front faces, thick white separators, black top facets, and white
right-side extrusion.  This is an alternative asset; it does not replace any
of the numbered square logo renders.

Usage from the repository root::

    python tools/render_anvil_wordmark.py
    python tools/render_anvil_wordmark.py --output tools/generated/anvil-logo-reconstructed-5.png
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw

from render_anvil_logo import render as render_anvil_a


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "tools" / "generated" / "anvil-logo-reconstructed-5.png"

CANVAS_WIDTH = 2048
CANVAS_HEIGHT = 1024
SUPERSAMPLE = 4

BLACK = (0, 0, 0, 255)
WHITE = (254, 254, 254, 255)

# The face plane keeps the same mild oblique slant as the original a.  Depth
# moves up/right, making the right sides white and the top facets black.
FACE_SKEW = 0.18
DEPTH = (60.0, -36.0)
FRONT_BORDER = 10.0

Point = tuple[float, float]
Polygon = tuple[Point, ...]


def scale_points(points: Iterable[Point], factor: float) -> list[tuple[int, int]]:
    return [(round(x * factor), round(y * factor)) for x, y in points]


def add(a: Point, b: Point) -> Point:
    return a[0] + b[0], a[1] + b[1]


def project(origin: Point, point: Point) -> Point:
    x, y = point
    return origin[0] + x, origin[1] + y + FACE_SKEW * x


def draw_polygon(
    draw: ImageDraw.ImageDraw,
    points: Sequence[Point],
    fill: tuple[int, int, int, int],
    factor: float,
) -> None:
    draw.polygon(scale_points(points, factor), fill=fill)


def rect(x0: float, y0: float, x1: float, y1: float) -> Polygon:
    return ((x0, y0), (x1, y0), (x1, y1), (x0, y1))


def glyph_geometry(letter: str, width: float, height: float) -> tuple[list[Polygon], list[tuple[Point, Point]]]:
    """Return front-face polygons and their black top edges."""

    thickness = max(32.0, round(width * 0.30))
    if letter == "n":
        faces = [
            rect(0, 0, thickness, height),
            rect(width - thickness, 0, width, height),
            rect(thickness, 0, width - thickness, thickness),
        ]
        top_edges = [((0, 0), (width, 0))]
    elif letter == "v":
        faces = [
            (
                (0, 0),
                (thickness, 0),
                (width / 2, height - thickness),
                (width - thickness, 0),
                (width, 0),
                (width / 2, height),
            )
        ]
        top_edges = [((0, 0), (thickness, 0)), ((width - thickness, 0), (width, 0))]
    elif letter == "i":
        stem_width = thickness * 0.82
        stem_x = (width - stem_width) / 2
        dot_width = width * 0.82
        dot_height = height * 0.16
        faces = [
            rect(stem_x, dot_height + thickness * 0.42, stem_x + stem_width, height),
            rect((width - dot_width) / 2, 0, (width + dot_width) / 2, dot_height),
        ]
        top_edges = [
            ((stem_x, dot_height + thickness * 0.42), (stem_x + stem_width, dot_height + thickness * 0.42)),
            (((width - dot_width) / 2, 0), ((width + dot_width) / 2, 0)),
        ]
    elif letter == "l":
        faces = [rect(0, 0, thickness, height)]
        top_edges = [((0, 0), (thickness, 0))]
    else:
        raise ValueError(f"unsupported wordmark glyph: {letter!r}")
    return faces, top_edges


def draw_custom_glyph(
    draw: ImageDraw.ImageDraw,
    letter: str,
    origin: Point,
    width: float,
    height: float,
    factor: float,
) -> None:
    faces, top_edges = glyph_geometry(letter, width, height)

    # Extruded side material behind the front faces.
    for face in faces:
        shifted = [add(project(origin, point), DEPTH) for point in face]
        draw_polygon(draw, shifted, WHITE, factor)

    # Black top facets are generated from selected front-plane edges.
    for edge_a, edge_b in top_edges:
        front_a = project(origin, edge_a)
        front_b = project(origin, edge_b)
        back_a = add(front_a, DEPTH)
        back_b = add(front_b, DEPTH)
        draw_polygon(draw, (front_a, front_b, back_b, back_a), BLACK, factor)

    front_faces = [[project(origin, point) for point in face] for face in faces]

    # White outlines first; black fills after them keep overlapping strokes
    # joined while retaining white separation between independent pieces such
    # as the i's dot and stem.
    for face in front_faces:
        scaled = scale_points(face, factor)
        draw.polygon(scaled, fill=WHITE)
        draw.line(
            scaled + [scaled[0]],
            fill=WHITE,
            width=max(1, round(FRONT_BORDER * 2.0 * factor)),
            joint="curve",
        )
    for face in front_faces:
        draw.polygon(scale_points(face, factor), fill=BLACK)


def load_existing_a(height: int, factor: int) -> Image.Image:
    """Render and crop the latest thick-border a for wordmark placement."""

    # Keep the last requested square glyph treatment: outer 12, inner 6.
    source = render_anvil_a(1024, factor, outer_border=12, inner_border=6)
    bbox = source.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("the reconstructed a rendered empty")
    source = source.crop(bbox)
    width = round(source.width * height / source.height)
    return source.resize((width * factor, height * factor), Image.Resampling.LANCZOS)


def render_wordmark(
    width: int = CANVAS_WIDTH,
    height: int = CANVAS_HEIGHT,
    factor: int = SUPERSAMPLE,
) -> Image.Image:
    if width < 1 or height < 1:
        raise ValueError("wordmark dimensions must be positive")
    if factor < 1:
        raise ValueError("supersample factor must be at least 1")

    geometry_scale = width / CANVAS_WIDTH * factor
    canvas = Image.new("RGBA", (width * factor, height * factor), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    a = load_existing_a(600, factor)
    a_width = a.width / factor
    n_width, v_width, i_width, l_width = 280.0, 290.0, 145.0, 135.0
    gap = 35.0
    total = a_width + n_width + v_width + i_width + l_width + gap * 4
    start_x = (CANVAS_WIDTH - total) / 2

    # Paste the actual existing a first, unchanged except for proportional
    # wordmark sizing.  Its transparent crop keeps the wordmark uncluttered.
    a_x = start_x
    a_y = 205.0
    canvas.alpha_composite(a, (round(a_x * factor), round(a_y * factor)))

    x = a_x + a_width + gap
    custom_y = 215.0
    for letter, letter_width in (
        ("n", n_width),
        ("v", v_width),
        ("i", i_width),
        ("l", l_width),
    ):
        draw_custom_glyph(draw, letter, (x, custom_y), letter_width, 560.0, geometry_scale)
        x += letter_width + gap

    if factor != 1:
        canvas = canvas.resize((width, height), Image.Resampling.LANCZOS)
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--width", type=int, default=CANVAS_WIDTH)
    parser.add_argument("--height", type=int, default=CANVAS_HEIGHT)
    parser.add_argument("--scale", type=int, default=SUPERSAMPLE)
    args = parser.parse_args()

    image = render_wordmark(args.width, args.height, args.scale)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output, optimize=True)
    print(f"wrote {args.output} ({args.width}x{args.height}, supersample {args.scale}x)")


if __name__ == "__main__":
    main()
