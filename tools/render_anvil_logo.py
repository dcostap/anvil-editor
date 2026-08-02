"""Render a vector reconstruction of the Anvil logo.

The reference PNG is a flat, black-and-white oblique extrusion.  It does not
contain enough information to recover a unique solid, so this renderer keeps
the useful parts separate:

* ``OUTER_TRACE`` is the 2-D traced envelope of the visible object.
* ``FRONT_TRACE`` and the smaller traces are the black regions on the front
  plane.  The white envelope showing through between them is what makes the
  heavy outline and the cut-outs.
* ``TOP_FRONT_EDGE``/``TOP_BACK_EDGE`` and ``SIDE_*`` are the inferred depth
  geometry.  ``draw_extruded_edge`` turns those 2-D rails into the top and
  right 3-D faces.

This is deliberately a small software renderer rather than a dependency on a
3-D package.  The trace is in reference-pixel coordinates, so changing the
silhouette means editing a readable list of points.  Supersampling and a
transparent downsample reproduce the crisp anti-aliased appearance of the
source artwork.

Usage from the repository root::

    python tools/render_anvil_logo.py
    python tools/render_anvil_logo.py --output /tmp/anvil-logo.png
    python tools/render_anvil_logo.py --outer-border 8
    python tools/render_anvil_logo.py --outer-border 12 --inner-border 6

The default output is ``tools/generated/anvil-logo-reconstructed.png`` and
never overwrites ``resources/icons/logo.png``.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable, Sequence

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "tools" / "generated" / "anvil-logo-reconstructed.png"

REFERENCE_SIZE = 1024
Point = tuple[float, float]

BLACK = (0, 0, 0, 255)
WHITE = (254, 254, 254, 255)

# Extra white material added outside the traced envelope.  This is deliberately
# separate from the black face traces: increasing it makes only the *outer*
# white border thicker, without widening the white separators inside the mark.
DEFAULT_OUTER_BORDER = 4.0

# Extra white drawn over the edges of the traced faces.  Unlike
# ``DEFAULT_OUTER_BORDER``, this widens the inner separators as well.
DEFAULT_INNER_BORDER = 0.0


# ---------------------------------------------------------------------------
# 2-D trace
# ---------------------------------------------------------------------------
#
# These are the coordinates of the solid/black boundaries, not the centres of
# an arbitrary stroke.  Keeping the white envelope underneath the black
# traces is what gives the source its intentionally wide white edges.

# The outer contour was traced from the non-transparent silhouette.  It also
# acts as the white outline/side material behind the front-plane cut-outs.
OUTER_TRACE: tuple[Point, ...] = (
    (450.0, 52.0),
    (256.0, 173.0),
    (256.0, 311.0),
    (367.0, 379.0),
    (217.0, 466.0),
    (217.0, 756.0),
    (505.0, 937.0),
    (547.0, 916.0),
    (631.0, 972.0),
    (805.0, 870.0),
    (805.0, 256.0),
)

# Main black front-plane trace.  The small jogs are real silhouette details;
# they are not rendering artefacts.
FRONT_TRACE: tuple[Point, ...] = (
    (274.0, 196.0),
    (274.0, 301.0),
    (515.0, 446.0),
    (515.0, 549.0),
    (501.0, 545.0),
    (339.0, 445.0),
    (336.0, 550.0),
    (234.0, 490.0),
    (234.0, 745.0),
    (491.0, 906.0),
    (493.0, 860.0),
    (594.0, 925.0),
    (594.0, 385.0),
)

# White front-plane recess.  The black quadrilateral inside it is another
# visible face, so it is drawn after this cut-out.
FRONT_RECESS: tuple[Point, ...] = (
    (320.0, 550.0),
    (515.0, 668.0),
    (513.0, 822.0),
    (319.0, 701.0),
)

# Black islands/faces visible through the traced white separations.  Their
# order is back-to-front at the few places where their outlines meet.
SECONDARY_BLACK_FACES: tuple[tuple[Point, ...], ...] = (
    (
        (339.0, 691.0),
        (495.0, 788.0),
        (494.0, 677.0),
        (426.0, 637.0),
    ),
    (
        (326.0, 415.0),
        (496.0, 518.0),
        (496.0, 456.0),
        (378.0, 385.0),
    ),
    (
        (317.0, 418.0),
        (235.0, 466.0),
        (318.0, 516.0),
    ),
    (
        (512.0, 895.0),
        (511.0, 928.0),
        (538.0, 912.0),
    ),
)


# ---------------------------------------------------------------------------
# Inferred extrusion/camera geometry
# ---------------------------------------------------------------------------
#
# The top black face is the extrusion of this front edge.  Its two rails are
# kept explicit because the source has a tiny amount of perspective/taper:
# the back rail is not exactly a constant screen-space translation of the
# front rail.
TOP_FRONT_EDGE: tuple[Point, Point] = (
    (273.0, 171.0),
    (610.0, 370.0),
)
TOP_BACK_EDGE: tuple[Point, Point] = (
    (453.0, 60.0),
    (796.0, 259.0),
)

# The large white wall is the right side of the extruded block.  It is drawn
# before the front traces; the front black plane hides the small overlap at
# the seam.
SIDE_FRONT_TOP = (610.0, 370.0)
SIDE_BACK_TOP = (805.0, 256.0)
SIDE_BACK_BOTTOM = (805.0, 870.0)
SIDE_FRONT_BOTTOM = (631.0, 972.0)


def scale_points(points: Iterable[Point], factor: float) -> list[tuple[int, int]]:
    return [(round(x * factor), round(y * factor)) for x, y in points]


def draw_polygon(
    draw: ImageDraw.ImageDraw,
    points: Sequence[Point],
    fill: tuple[int, int, int, int] | int,
    geometry_scale: float,
) -> None:
    draw.polygon(scale_points(points, geometry_scale), fill=fill)


def draw_extruded_edge(
    draw: ImageDraw.ImageDraw,
    front_edge: Sequence[Point],
    back_edge: Sequence[Point],
    fill: tuple[int, int, int, int],
    geometry_scale: float,
) -> None:
    """Turn two 2-D rails into a single visible 3-D side face."""

    if len(front_edge) != 2 or len(back_edge) != 2:
        raise ValueError("an extruded edge needs two points on each rail")
    draw_polygon(
        draw,
        (front_edge[0], front_edge[1], back_edge[1], back_edge[0]),
        fill,
        geometry_scale,
    )


def draw_outer_material(
    canvas: Image.Image,
    outer_trace: Sequence[Point],
    geometry_scale: float,
    border_pixels: float,
) -> None:
    """Paint the white envelope with an optional outward border."""

    draw = ImageDraw.Draw(canvas)
    draw_polygon(draw, outer_trace, WHITE, geometry_scale)
    if border_pixels <= 0:
        return

    # A closed, thick line is an efficient vector dilation for this small
    # traced envelope.  The inside half is already white; the outside half is
    # the extra border.  Drawing at supersampled resolution keeps the result
    # fast even when the user experiments with large border values.
    outline = scale_points(outer_trace, geometry_scale)
    draw.line(
        outline + [outline[0]],
        fill=WHITE,
        width=max(1, round(border_pixels * 2.0 * geometry_scale)),
        joint="curve",
    )


def draw_inner_border(
    draw: ImageDraw.ImageDraw,
    trace: Sequence[Point],
    geometry_scale: float,
    border_pixels: float,
) -> None:
    """Draw an extra white stroke inward from one traced face boundary."""

    if border_pixels <= 0:
        return
    outline = scale_points(trace, geometry_scale)
    draw.line(
        outline + [outline[0]],
        fill=WHITE,
        width=max(1, round(border_pixels * 2.0 * geometry_scale)),
        joint="curve",
    )


def render(
    size: int = REFERENCE_SIZE,
    supersample: int = 4,
    outer_border: float = DEFAULT_OUTER_BORDER,
    inner_border: float = DEFAULT_INNER_BORDER,
) -> Image.Image:
    """Render the reconstructed mark as a transparent RGBA image."""

    if size < 1:
        raise ValueError("size must be positive")
    if supersample < 1:
        raise ValueError("supersample must be at least 1")
    if outer_border < 0:
        raise ValueError("outer_border must not be negative")
    if inner_border < 0:
        raise ValueError("inner_border must not be negative")

    # Geometry is authored at 1024 reference pixels and then scaled together
    # with the supersampling factor.  This keeps --size useful for icon tests.
    geometry_scale = size / REFERENCE_SIZE * supersample
    working_size = size * supersample
    canvas = Image.new("RGBA", (working_size, working_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # White material first: it supplies both the outer outline and the white
    # portions of the recessed front faces.  The optional dilation is applied
    # before the black traces, so it affects only the outside border.
    draw_outer_material(canvas, OUTER_TRACE, geometry_scale, outer_border)
    draw = ImageDraw.Draw(canvas)

    # Explicit 3-D side faces.  The white wall is already contained by the
    # traced envelope, but drawing it as a mesh face keeps the construction
    # meaningful when the rails are edited.
    draw_polygon(
        draw,
        (SIDE_FRONT_TOP, SIDE_BACK_TOP, SIDE_BACK_BOTTOM, SIDE_FRONT_BOTTOM),
        WHITE,
        geometry_scale,
    )
    draw_extruded_edge(
        draw,
        TOP_FRONT_EDGE,
        TOP_BACK_EDGE,
        BLACK,
        geometry_scale,
    )

    # Front black geometry and its recesses.
    draw_polygon(draw, FRONT_TRACE, BLACK, geometry_scale)
    draw_polygon(draw, FRONT_RECESS, WHITE, geometry_scale)
    for face in SECONDARY_BLACK_FACES:
        draw_polygon(draw, face, BLACK, geometry_scale)

    # Widen the white separators by painting into the edges of every visible
    # black/white face.  The outer envelope is intentionally excluded here;
    # its thickness is controlled independently by outer_border.
    if inner_border > 0:
        top_face = (
            TOP_FRONT_EDGE[0],
            TOP_FRONT_EDGE[1],
            TOP_BACK_EDGE[1],
            TOP_BACK_EDGE[0],
        )
        for trace in (top_face, FRONT_TRACE, FRONT_RECESS, *SECONDARY_BLACK_FACES):
            draw_inner_border(draw, trace, geometry_scale, inner_border)

    # Downsampling from transparency avoids a dark fringe at the white/clear
    # boundary.  Pillow's LANCZOS pass also supplies the source-like edge
    # antialiasing.
    if supersample != 1:
        canvas = canvas.resize((size, size), Image.Resampling.LANCZOS)
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--size", type=int, default=REFERENCE_SIZE)
    parser.add_argument("--scale", type=int, default=4, help="supersampling factor")
    parser.add_argument(
        "--outer-border",
        type=float,
        default=DEFAULT_OUTER_BORDER,
        help="extra outer white border in reference pixels (default: %(default)s)",
    )
    parser.add_argument(
        "--inner-border",
        type=float,
        default=DEFAULT_INNER_BORDER,
        help="extra inner white border in reference pixels (default: %(default)s)",
    )
    args = parser.parse_args()

    if args.size < 1:
        parser.error("--size must be positive")
    if args.scale < 1:
        parser.error("--scale must be at least 1")
    if args.outer_border < 0:
        parser.error("--outer-border must not be negative")
    if args.inner_border < 0:
        parser.error("--inner-border must not be negative")

    image = render(args.size, args.scale, args.outer_border, args.inner_border)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output, optimize=True)
    print(f"wrote {args.output} ({args.size}x{args.size}, supersample {args.scale}x)")


if __name__ == "__main__":
    main()
