#include "image_scale.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef __SSE2__
#include <emmintrin.h>
#endif

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

/* Interpolate four packed RGBA32 pixels with the same alpha: first each row, then between the rows.
   With equal alpha, weighting colour by coverage changes nothing.
   Each step rounds to 8 bits. Both versions give the same result. */
#ifdef __SSE2__
typedef __m128i PairWeights;

/* Weights for _mm_madd_epi16 on interleaved pairs: 256 - w for the first value, w for the second. */
static inline __m128i pair_weights(uint32_t w) {
  return _mm_set1_epi32((int)(w << 16 | (256 - w)));
}

/* Interleave the 16-bit channels of a and b, then return (a * (256 - w) + b * w + 128) >> 8 in 32-bit lanes. */
static inline __m128i lerp_pairs(__m128i a, __m128i b, __m128i weights) {
  __m128i sum = _mm_madd_epi16(_mm_unpacklo_epi16(a, b), weights);
  return _mm_srli_epi32(_mm_add_epi32(sum, _mm_set1_epi32(128)), 8);
}

static inline __m128i widen(uint32_t pixel) {
  return _mm_unpacklo_epi8(_mm_cvtsi32_si128((int)pixel), _mm_setzero_si128());
}

static inline uint32_t bilinear_packed(uint32_t q00, uint32_t q01, uint32_t q10, uint32_t q11,
                                       __m128i wx, __m128i wy) {
  __m128i top = lerp_pairs(widen(q00), widen(q01), wx);
  __m128i bottom = lerp_pairs(widen(q10), widen(q11), wx);
  /* Both rows fit in 16 bits again: top in lanes 0 to 3, bottom in lanes 4 to 7. */
  __m128i rows = _mm_packs_epi32(top, bottom);
  __m128i result = lerp_pairs(rows, _mm_srli_si128(rows, 8), wy);
  result = _mm_packs_epi32(result, result);
  return (uint32_t)_mm_cvtsi128_si32(_mm_packus_epi16(result, result));
}
#else
typedef uint32_t PairWeights;

static inline uint32_t pair_weights(uint32_t w) {
  return w;
}

/* Two channels for each multiply. Each 16-bit lane stays below 65536. */
static inline uint32_t lerp_packed(uint32_t a, uint32_t b, uint32_t w) {
  uint32_t rb = (((a & 0xff00ff) * (256 - w) + (b & 0xff00ff) * w + 0x800080) >> 8) & 0xff00ff;
  uint32_t ga = (((a >> 8) & 0xff00ff) * (256 - w) + ((b >> 8) & 0xff00ff) * w + 0x800080) & 0xff00ff00;
  return rb | ga;
}

static inline uint32_t bilinear_packed(uint32_t q00, uint32_t q01, uint32_t q10, uint32_t q11,
                                       uint32_t wx, uint32_t wy) {
  return lerp_packed(lerp_packed(q00, q01, wx), lerp_packed(q10, q11, wx), wy);
}
#endif

static inline Uint8 scale255(uint32_t value, uint32_t factor) {
  return (Uint8)((value * factor + 127) / 255);
}

/* Blend each byte of s over d with alpha a: (s * a + d * (255 - a)) / 255, rounded.
   An alpha byte of 255 in s gives the usual a + d * (255 - a) / 255. */
#ifdef __SSE2__
static inline uint32_t blend_over(uint32_t s, uint32_t d, uint32_t a) {
  __m128i sum = _mm_madd_epi16(_mm_unpacklo_epi16(widen(s), widen(d)),
                               _mm_set1_epi32((int)((255 - a) << 16 | a)));
  sum = _mm_add_epi32(sum, _mm_set1_epi32(128));
  sum = _mm_srli_epi32(_mm_add_epi32(sum, _mm_srli_epi32(sum, 8)), 8);
  sum = _mm_packs_epi32(sum, sum);
  return (uint32_t)_mm_cvtsi128_si32(_mm_packus_epi16(sum, sum));
}
#else
static inline uint32_t blend_over(uint32_t s, uint32_t d, uint32_t a) {
  uint32_t result = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    uint32_t sum = ((s >> shift) & 0xff) * a + ((d >> shift) & 0xff) * (255 - a) + 128;
    result |= ((sum + (sum >> 8)) >> 8) << shift;
  }
  return result;
}
#endif

/* Draw straight into a 32-bit surface with 8-bit channels, without a scratch surface and a second blend. */
static bool draw_direct(SDL_Surface *src, SDL_Surface *dst, const Tap *columns, const Tap *rows,
                        int x0, int y0, int cw, int ch, SDL_Color color, bool blend) {
  const SDL_PixelFormatDetails *d = SDL_GetPixelFormatDetails(dst->format);
  if (!d || d->bytes_per_pixel != 4 || d->Rbits != 8 || d->Gbits != 8 || d->Bbits != 8
      || (d->Abits != 0 && d->Abits != 8)) {
    return false;
  }
  bool tint = color.r != 255 || color.g != 255 || color.b != 255;
  /* An opaque pixel with a white, opaque colour replaces the old pixel. */
  bool plain = !tint && color.a == 255;
  const int rs = d->Rshift, gs = d->Gshift, bs = d->Bshift;
  const uint32_t amask = d->Amask;
  const Uint8 *pixels = src->pixels;
  for (int j = 0; j < ch; j++) {
    const Uint8 *row0 = pixels + (size_t)rows[j].first * src->pitch;
    const Uint8 *row1 = pixels + (size_t)rows[j].second * src->pitch;
    uint32_t wy = (uint32_t)rows[j].weight;
    PairWeights wy_pair = pair_weights(wy);
    uint32_t *out = (uint32_t *)((Uint8 *)dst->pixels + (size_t)(y0 + j) * dst->pitch) + x0;
    for (int i = 0; i < cw; i++) {
      const Tap *col = &columns[i];
      uint32_t wx = (uint32_t)col->weight;
      uint32_t q00 = ((const uint32_t *)row0)[col->first], q01 = ((const uint32_t *)row0)[col->second];
      uint32_t q10 = ((const uint32_t *)row1)[col->first], q11 = ((const uint32_t *)row1)[col->second];
      Uint8 s[4];
      uint32_t alpha = q00 >> 24;
      if ((q01 >> 24) == alpha && (q10 >> 24) == alpha && (q11 >> 24) == alpha) {
        if (alpha == 0 && blend) continue;
        uint32_t p = bilinear_packed(q00, q01, q10, q11, pair_weights(wx), wy_pair);
        if (alpha == 255 && plain) {
          out[i] = (p & 0xff) << rs | (p >> 8 & 0xff) << gs | (p >> 16 & 0xff) << bs | amask;
          continue;
        }
        s[0] = (Uint8)p, s[1] = (Uint8)(p >> 8), s[2] = (Uint8)(p >> 16), s[3] = (Uint8)alpha;
      } else {
        sample(row0 + col->first * 4, row0 + col->second * 4, row1 + col->first * 4, row1 + col->second * 4,
               wx, wy, s);
      }
      if (tint) s[0] = scale255(s[0], color.r), s[1] = scale255(s[1], color.g), s[2] = scale255(s[2], color.b);
      uint32_t a = color.a == 255 ? s[3] : scale255(s[3], color.a);
      uint32_t colour = (uint32_t)s[0] << rs | (uint32_t)s[1] << gs | (uint32_t)s[2] << bs;
      if (!blend || a == 255) {
        out[i] = colour | (amask ? a << d->Ashift : 0);
        continue;
      }
      if (a != 0) out[i] = blend_over(colour | amask, out[i], a);
    }
  }
  return true;
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
  bool ok = ensure_taps(cw + ch);
  Tap *columns = taps, *rows = taps + cw;
  SDL_BlendMode blend;
  SDL_GetSurfaceBlendMode(src, &blend);
  if (ok) {
    fill_taps(columns, x0, cw, x, rgba->w / w, rgba->w);
    fill_taps(rows, y0, ch, y, rgba->h / h, rgba->h);
  }
  bool done = ok && (blend == SDL_BLENDMODE_NONE || blend == SDL_BLENDMODE_BLEND)
    && draw_direct(rgba, dst, columns, rows, x0, y0, cw, ch, color,
                   blend == SDL_BLENDMODE_BLEND || color.a < 255);
  ok = ok && (done || ensure_scratch(cw, ch));
  if (ok && !done) {
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
    SDL_SetSurfaceBlendMode(scratch, color.a < 255 ? SDL_BLENDMODE_BLEND : blend);
    SDL_SetSurfaceColorMod(scratch, color.r, color.g, color.b);
    SDL_SetSurfaceAlphaMod(scratch, color.a);
    SDL_Rect area = { 0, 0, cw, ch }, position = { x0, y0, cw, ch };
    ok = SDL_BlitSurface(scratch, &area, dst, &position);
  }
  if (rgba != src) SDL_DestroySurface(rgba);
  return ok;
}
