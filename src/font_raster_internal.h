#ifndef ANVIL_FONT_RASTER_INTERNAL_H
#define ANVIL_FONT_RASTER_INTERNAL_H

#include <math.h>
#include <stdbool.h>

#define ANVIL_FONT_SUBPIXEL_PHASES 3

typedef struct {
  int pixel_x;
  unsigned int bitmap_index;
} GlyphXPlacement;

static inline GlyphXPlacement font_quantize_glyph_x_value(
  bool uses_lcd_coverage, double x
) {
  if (!uses_lcd_coverage)
    return (GlyphXPlacement) { .pixel_x = (int)floor(x), .bitmap_index = 0 };

  int q = (int)floor(x * ANVIL_FONT_SUBPIXEL_PHASES + 0.5);
  int pixel_x = q / ANVIL_FONT_SUBPIXEL_PHASES;
  int remainder = q % ANVIL_FONT_SUBPIXEL_PHASES;
  if (remainder < 0) {
    remainder += ANVIL_FONT_SUBPIXEL_PHASES;
    pixel_x -= 1;
  }
  return (GlyphXPlacement) {
    .pixel_x = pixel_x,
    .bitmap_index = (unsigned int)remainder,
  };
}

#endif
