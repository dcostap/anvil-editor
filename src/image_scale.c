#include "image_scale.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>

/* One source column or row for a destination pixel: two neighbours and the weight of the second, 0 to 256. */
typedef struct { int first, second, weight; } Tap;

/* Reused for each draw on the same thread. Its size follows the largest visible area. */
static _Thread_local SDL_Surface *scratch;
static _Thread_local Tap *taps;
static _Thread_local int tap_capacity;

static bool ensure_scratch(int w, int h) {
  if (scratch && scratch->w >= w && scratch->h >= h) return true;
  int sw = scratch && scratch->w > w ? scratch->w : w;
  int sh = scratch && scratch->h > h ? scratch->h : h;
  SDL_DestroySurface(scratch);
  scratch = SDL_CreateSurface(sw, sh, SDL_PIXELFORMAT_RGBA32);
  return scratch != NULL;
}

static bool ensure_taps(int count) {
  if (count <= tap_capacity) return true;
  Tap *grown = realloc(taps, sizeof(Tap) * (size_t)count);
  if (!grown) return false;
  taps = grown;
  tap_capacity = count;
  return true;
}

/* Sample at pixel centres, as the D3D11 renderer does, and clamp at the image edges. */
static void fill_taps(Tap *out, int first, int count, double origin, double scale, int size) {
  for (int i = 0; i < count; i++) {
    double u = (first + i + 0.5 - origin) * scale - 0.5;
    double base = floor(u);
    int a = (int)base;
    int weight = (int)((u - base) * 256.0 + 0.5);
    int b = a + 1;
    if (a < 0) a = 0;
    if (b < 0) b = 0;
    if (a >= size) a = size - 1;
    if (b >= size) b = size - 1;
    out[i] = (Tap){ a, b, weight };
  }
}

/* Interpolate four RGBA pixels with colour weighted by coverage, then store straight alpha. */
static void sample(const Uint8 *p00, const Uint8 *p01, const Uint8 *p10, const Uint8 *p11,
                   uint32_t wx, uint32_t wy, Uint8 *out) {
  uint32_t w00 = (256 - wx) * (256 - wy), w01 = wx * (256 - wy);
  uint32_t w10 = (256 - wx) * wy, w11 = wx * wy;
  if ((p00[3] & p01[3] & p10[3] & p11[3]) == 255) {
    for (int c = 0; c < 3; c++) {
      out[c] = (Uint8)((p00[c] * w00 + p01[c] * w01 + p10[c] * w10 + p11[c] * w11 + 32768) >> 16);
    }
    out[3] = 255;
    return;
  }
  /* Each sum stays below 255 * 255 * 65536, inside 32 bits. */
  uint32_t a00 = p00[3] * w00, a01 = p01[3] * w01, a10 = p10[3] * w10, a11 = p11[3] * w11;
  uint32_t coverage = a00 + a01 + a10 + a11;
  if (coverage == 0) {
    out[0] = out[1] = out[2] = out[3] = 0;
    return;
  }
  for (int c = 0; c < 3; c++) {
    uint32_t sum = p00[c] * a00 + p01[c] * a01 + p10[c] * a10 + p11[c] * a11;
    out[c] = (Uint8)((sum + coverage / 2) / coverage);
  }
  out[3] = (Uint8)((coverage + 32768) >> 16);
}

static bool blit_unscaled(SDL_Surface *src, SDL_Surface *dst, int x, int y, SDL_Color color) {
  Uint8 old_r, old_g, old_b, old_a;
  SDL_BlendMode old_blend;
  SDL_GetSurfaceColorMod(src, &old_r, &old_g, &old_b);
  SDL_GetSurfaceAlphaMod(src, &old_a);
  SDL_GetSurfaceBlendMode(src, &old_blend);
  SDL_SetSurfaceColorMod(src, color.r, color.g, color.b);
  SDL_SetSurfaceAlphaMod(src, color.a);
  if (color.a < 255) SDL_SetSurfaceBlendMode(src, SDL_BLENDMODE_BLEND);
  SDL_Rect position = { x, y, 0, 0 };
  bool ok = SDL_BlitSurface(src, NULL, dst, &position);
  SDL_SetSurfaceColorMod(src, old_r, old_g, old_b);
  SDL_SetSurfaceAlphaMod(src, old_a);
  SDL_SetSurfaceBlendMode(src, old_blend);
  return ok;
}

bool image_scale_blit(SDL_Surface *src, SDL_Surface *dst, double x, double y, double w, double h,
                      SDL_Color color) {
  if (!src || !dst || src->w <= 0 || src->h <= 0 || !(w > 0) || !(h > 0) || color.a == 0) return true;
  if (w == src->w && h == src->h && x == floor(x) && y == floor(y)
      && fabs(x) < INT32_MAX && fabs(y) < INT32_MAX) {
    return blit_unscaled(src, dst, (int)x, (int)y, color);
  }

  /* Draw the pixels whose centres are inside the rectangle and the clip rect. */
  SDL_Rect clip;
  SDL_GetSurfaceClipRect(dst, &clip);
  double left = fmax(ceil(x - 0.5), clip.x), right = fmin(ceil(x + w - 0.5), clip.x + clip.w);
  double top = fmax(ceil(y - 0.5), clip.y), bottom = fmin(ceil(y + h - 0.5), clip.y + clip.h);
  if (!(right > left) || !(bottom > top)) return true;
  int x0 = (int)left, y0 = (int)top, cw = (int)(right - left), ch = (int)(bottom - top);

  SDL_Surface *rgba = src;
  if (src->format != SDL_PIXELFORMAT_RGBA32) {
    rgba = SDL_ConvertSurface(src, SDL_PIXELFORMAT_RGBA32);
    if (!rgba) return false;
  }
  bool ok = ensure_scratch(cw, ch) && ensure_taps(cw + ch);
  if (ok) {
    Tap *columns = taps, *rows = taps + cw;
    fill_taps(columns, x0, cw, x, rgba->w / w, rgba->w);
    fill_taps(rows, y0, ch, y, rgba->h / h, rgba->h);
    const Uint8 *pixels = rgba->pixels;
    for (int j = 0; j < ch; j++) {
      const Uint8 *row0 = pixels + (size_t)rows[j].first * rgba->pitch;
      const Uint8 *row1 = pixels + (size_t)rows[j].second * rgba->pitch;
      Uint8 *out = (Uint8 *)scratch->pixels + (size_t)j * scratch->pitch;
      for (int i = 0; i < cw; i++, out += 4) {
        const Tap *col = &columns[i];
        sample(row0 + col->first * 4, row0 + col->second * 4, row1 + col->first * 4, row1 + col->second * 4,
               (uint32_t)col->weight, (uint32_t)rows[j].weight, out);
      }
    }
    SDL_BlendMode blend;
    SDL_GetSurfaceBlendMode(src, &blend);
    SDL_SetSurfaceBlendMode(scratch, color.a < 255 ? SDL_BLENDMODE_BLEND : blend);
    SDL_SetSurfaceColorMod(scratch, color.r, color.g, color.b);
    SDL_SetSurfaceAlphaMod(scratch, color.a);
    SDL_Rect area = { 0, 0, cw, ch }, position = { x0, y0, cw, ch };
    ok = SDL_BlitSurface(scratch, &area, dst, &position);
  }
  if (rgba != src) SDL_DestroySurface(rgba);
  return ok;
}
