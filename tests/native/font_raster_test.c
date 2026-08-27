#include <stdio.h>
#include "../../src/font_raster_internal.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    return 1; \
  } \
} while (0)

static int check_lcd(double x, int pixel_x, unsigned int bitmap_index) {
  GlyphXPlacement placement = font_quantize_glyph_x_value(true, x);
  CHECK(placement.pixel_x == pixel_x);
  CHECK(placement.bitmap_index == bitmap_index);
  return 0;
}

int main(void) {
  CHECK(check_lcd(0.0, 0, 0) == 0);
  CHECK(check_lcd(1.0 / 6.0, 0, 1) == 0);
  CHECK(check_lcd(1.0 / 6.0 - 0.0001, 0, 0) == 0);
  CHECK(check_lcd(1.0 / 6.0 + 0.0001, 0, 1) == 0);
  CHECK(check_lcd(0.5, 0, 2) == 0);
  CHECK(check_lcd(0.5 - 0.0001, 0, 1) == 0);
  CHECK(check_lcd(0.5 + 0.0001, 0, 2) == 0);
  CHECK(check_lcd(5.0 / 6.0, 1, 0) == 0);
  CHECK(check_lcd(5.0 / 6.0 - 0.0001, 0, 2) == 0);
  CHECK(check_lcd(5.0 / 6.0 + 0.0001, 1, 0) == 0);
  CHECK(check_lcd(0.99, 1, 0) == 0);

  CHECK(check_lcd(-1.0 / 6.0, 0, 0) == 0);
  CHECK(check_lcd(-0.5, -1, 2) == 0);
  CHECK(check_lcd(-5.0 / 6.0, -1, 1) == 0);
  CHECK(check_lcd(-0.99, -1, 0) == 0);

  for (int step = -30; step <= 30; step++) {
    double x = step / 10.0 + 1.0 / 6.0;
    GlyphXPlacement first = font_quantize_glyph_x_value(true, x);
    GlyphXPlacement next = font_quantize_glyph_x_value(true, x + 1.0);
    int first_q = first.pixel_x * ANVIL_FONT_SUBPIXEL_PHASES
      + (int)first.bitmap_index;
    int next_q = next.pixel_x * ANVIL_FONT_SUBPIXEL_PHASES
      + (int)next.bitmap_index;
    CHECK(next_q == first_q + ANVIL_FONT_SUBPIXEL_PHASES);
  }

  GlyphXPlacement grayscale = font_quantize_glyph_x_value(false, -0.25);
  CHECK(grayscale.pixel_x == -1);
  CHECK(grayscale.bitmap_index == 0);
  return 0;
}
