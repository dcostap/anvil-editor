#include "terminal_contrast.h"

#include <math.h>
#include <ghostty/vt.h>

typedef struct { double l, a, b; } Oklab;
typedef struct { double r, g, b; } LinearRgb;

static GhosttyColorRgb unpack(uint32_t color) {
  return (GhosttyColorRgb) { color >> 16, color >> 8, color };
}

static uint32_t pack(GhosttyColorRgb color) {
  return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | color.b;
}

uint32_t terminal_color_blend(uint32_t foreground, uint32_t background, uint8_t alpha) {
  GhosttyColorRgb fg = unpack(foreground), bg = unpack(background);
  return pack((GhosttyColorRgb) {
    (fg.r * alpha + bg.r * (255 - alpha) + 127) / 255,
    (fg.g * alpha + bg.g * (255 - alpha) + 127) / 255,
    (fg.b * alpha + bg.b * (255 - alpha) + 127) / 255,
  });
}

bool terminal_contrast_graphics(uint32_t codepoint) {
  return (codepoint >= 0x2500 && codepoint <= 0x259f) ||
    (codepoint >= 0x1fb00 && codepoint <= 0x1fbff) ||
    (codepoint >= 0x1cc00 && codepoint <= 0x1cebf) ||
    (codepoint >= 0xe0b0 && codepoint <= 0xe0d7);
}

static double linear(uint8_t channel) {
  double value = channel / 255.0;
  return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static uint8_t encoded(double channel) {
  channel = fmax(0, fmin(1, channel));
  double value = channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055;
  return (uint8_t)lround(value * 255);
}

// Oklab matrices from Bjorn Ottosson's public-domain reference code.
// https://bottosson.github.io/posts/oklab/
static Oklab to_oklab(uint32_t color) {
  GhosttyColorRgb rgb = unpack(color);
  double r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b);
  double l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  double m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  double s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return (Oklab) {
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  };
}

static LinearRgb from_oklab(Oklab color) {
  double l = color.l + 0.3963377774 * color.a + 0.2158037573 * color.b;
  double m = color.l - 0.1055613458 * color.a - 0.0638541728 * color.b;
  double s = color.l - 0.0894841775 * color.a - 1.2914855480 * color.b;
  l = l * l * l; m = m * m * m; s = s * s * s;
  return (LinearRgb) {
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  };
}

static bool in_gamut(LinearRgb rgb) {
  return rgb.r >= 0 && rgb.r <= 1 && rgb.g >= 0 && rgb.g <= 1 && rgb.b >= 0 && rgb.b <= 1;
}

static uint32_t gamut_color(Oklab color) {
  LinearRgb rgb = from_oklab(color);
  if (!in_gamut(rgb)) {
    // Reduce chroma, not hue, until the color fits sRGB.
    double low = 0, high = 1;
    rgb = from_oklab((Oklab) { color.l, 0, 0 });
    for (int i = 0; i < 10; i++) {
      double scale = (low + high) / 2;
      LinearRgb candidate = from_oklab((Oklab) { color.l, color.a * scale, color.b * scale });
      if (in_gamut(candidate)) { low = scale; rgb = candidate; }
      else high = scale;
    }
  }
  return pack((GhosttyColorRgb) { encoded(rgb.r), encoded(rgb.g), encoded(rgb.b) });
}

static double ratio(uint32_t fg, uint32_t bg) {
  GhosttyColorRgb foreground = unpack(fg), background = unpack(bg);
  return ghostty_color_contrast(&foreground, &background);
}

static uint32_t corrected_color(uint32_t foreground, uint32_t background, double minimum) {
  Oklab original = to_oklab(foreground);
  uint32_t best = ratio(0, background) >= ratio(0xffffff, background) ? 0 : 0xffffff;
  double best_change = 2;
  for (int direction = 0; direction < 2; direction++) {
    uint32_t endpoint = direction ? 0xffffff : 0;
    if (ratio(endpoint, background) < minimum) continue;
    double low = 0, high = 1;
    uint32_t result = endpoint;
    for (int i = 0; i < 12; i++) {
      double step = (low + high) / 2;
      Oklab candidate = original;
      candidate.l += ((double)direction - original.l) * step;
      uint32_t color = gamut_color(candidate);
      // Check the final 8-bit RGB value, not the unquantized Oklab value.
      if (ratio(color, background) >= minimum) { high = step; result = color; }
      else low = step;
    }
    double change = fabs(((double)direction - original.l) * high);
    if (change < best_change) { best_change = change; best = result; }
  }
  // Some backgrounds cannot meet a high requested ratio. Use the best endpoint.
  return best;
}

TerminalInk terminal_contrast_ink(
  TerminalContrast *contrast, uint32_t foreground, uint32_t background,
  uint8_t alpha, uint32_t codepoint
) {
  TerminalInk result = { foreground, alpha };
  if (contrast->minimum <= 1 || alpha == 0 || terminal_contrast_graphics(codepoint)) return result;
  uint32_t hash = foreground * 2654435761u ^ background * 2246822519u ^ alpha;
  TerminalContrastEntry *entry = &contrast->entries[hash & (TERMINAL_CONTRAST_CACHE_SIZE - 1)];
  if (entry->valid && entry->foreground == foreground && entry->background == background && entry->alpha == alpha) {
    return entry->result;
  }
  uint32_t visible = terminal_color_blend(foreground, background, alpha);
  if (ratio(visible, background) < contrast->minimum) {
    result.foreground = corrected_color(visible, background, contrast->minimum);
    result.alpha = 255;
  }
  *entry = (TerminalContrastEntry) { foreground, background, alpha, true, result };
  return result;
}
