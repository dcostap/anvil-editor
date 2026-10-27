#include <stdio.h>
#include <string.h>
#include "../../src/image_scale.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    return 1; \
  } \
} while (0)

static const SDL_Color WHITE = { 255, 255, 255, 255 };

static SDL_Surface *image(int w, int h, const Uint8 *rgba) {
  SDL_Surface *surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
  for (int y = 0; y < h; y++) memcpy((Uint8 *)surface->pixels + y * surface->pitch, rgba + y * w * 4, w * 4);
  return surface;
}

/* A window surface: opaque, without an alpha channel. */
static SDL_Surface *screen(int w, int h, Uint8 r, Uint8 g, Uint8 b) {
  SDL_Surface *surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_XRGB8888);
  SDL_FillSurfaceRect(surface, NULL, SDL_MapSurfaceRGB(surface, r, g, b));
  return surface;
}

static SDL_Color pixel(SDL_Surface *surface, int x, int y) {
  SDL_Color c;
  SDL_ReadSurfacePixel(surface, x, y, &c.r, &c.g, &c.b, &c.a);
  return c;
}

/* A zoom far beyond the window draws the part that the window shows. */
static int deep_zoom_draws_visible_part(void) {
  const Uint8 rgba[] = {
    255, 0, 0, 255,  255, 0, 0, 255,  0, 0, 255, 255,  0, 0, 255, 255,
    255, 0, 0, 255,  255, 0, 0, 255,  0, 0, 255, 255,  0, 0, 255, 255,
  };
  SDL_Surface *src = image(4, 2, rgba);
  SDL_Surface *dst = screen(64, 64, 0, 0, 0);
  /* 100000 screen pixels for each source pixel. The window shows the edge between source columns 0 and 1. */
  CHECK(image_scale_blit(src, dst, -100000, -50000, 400000, 200000, WHITE));
  SDL_Color c = pixel(dst, 10, 10);
  CHECK(c.r == 255 && c.g == 0 && c.b == 0);
  SDL_DestroySurface(src);
  SDL_DestroySurface(dst);
  return 0;
}

static bool same_pixels(SDL_Surface *a, SDL_Surface *b) {
  for (int y = 0; y < a->h; y++) {
    if (memcmp((Uint8 *)a->pixels + y * a->pitch, (Uint8 *)b->pixels + y * b->pitch, a->w * 4)) return false;
  }
  return true;
}

/* The renderer draws each changed screen area with its own clip rect. The areas must join exactly. */
static int clipped_draws_join_without_seams(void) {
  Uint8 rgba[7 * 5 * 4];
  for (int i = 0; i < 7 * 5; i++) {
    rgba[i * 4 + 0] = (Uint8)(i * 37);
    rgba[i * 4 + 1] = (Uint8)(i * 91);
    rgba[i * 4 + 2] = (Uint8)(255 - i * 13);
    rgba[i * 4 + 3] = (Uint8)(i % 3 == 0 ? 255 : 120 + i * 3);
  }
  SDL_Surface *src = image(7, 5, rgba);
  SDL_Surface *whole = screen(50, 40, 20, 30, 40);
  SDL_Surface *parts = screen(50, 40, 20, 30, 40);
  CHECK(image_scale_blit(src, whole, 3.3, 2.7, 37.9, 31.1, WHITE));
  const SDL_Rect areas[] = { { 0, 0, 23, 17 }, { 23, 0, 27, 17 }, { 0, 17, 50, 23 } };
  for (int i = 0; i < 3; i++) {
    SDL_SetSurfaceClipRect(parts, &areas[i]);
    CHECK(image_scale_blit(src, parts, 3.3, 2.7, 37.9, 31.1, WHITE));
  }
  CHECK(same_pixels(whole, parts));
  SDL_DestroySurface(src);
  SDL_DestroySurface(whole);
  SDL_DestroySurface(parts);
  return 0;
}

/* Filtering weighs colour by coverage, so a transparent neighbour cannot darken an edge. */
static int transparent_neighbour_keeps_edge_colour(void) {
  const Uint8 rgba[] = { 255, 0, 0, 255,  0, 0, 0, 0 };
  SDL_Surface *src = image(2, 1, rgba);
  SDL_Surface *dst = screen(20, 1, 255, 255, 255);
  CHECK(image_scale_blit(src, dst, 0, 0, 20, 1, WHITE));
  /* Halfway between the texels: half coverage of pure red over white. */
  SDL_Color c = pixel(dst, 10, 0);
  CHECK(c.r >= 250);
  CHECK(c.g > 100 && c.g < 160 && c.g == c.b);
  SDL_DestroySurface(src);
  SDL_DestroySurface(dst);
  return 0;
}

/* The colour's alpha fades the image. */
static int colour_alpha_sets_opacity(void) {
  const Uint8 rgba[] = { 255, 255, 255, 255 };
  SDL_Surface *src = image(1, 1, rgba);
  SDL_Surface *dst = screen(8, 8, 0, 0, 0);
  CHECK(image_scale_blit(src, dst, 0, 0, 8, 8, (SDL_Color){ 255, 255, 255, 128 }));
  SDL_Color c = pixel(dst, 4, 4);
  CHECK(c.r > 120 && c.r < 136);
  SDL_DestroySurface(src);
  SDL_DestroySurface(dst);
  return 0;
}

/* A translucent image blends with the pixels under it. */
static int translucent_image_blends(void) {
  const Uint8 rgba[] = { 255, 0, 0, 128,  255, 0, 0, 128,  255, 0, 0, 128,  255, 0, 0, 128 };
  SDL_Surface *src = image(2, 2, rgba);
  SDL_Surface *dst = screen(8, 8, 0, 0, 255);
  CHECK(image_scale_blit(src, dst, 0, 0, 8, 8, WHITE));
  SDL_Color c = pixel(dst, 4, 4);
  CHECK(c.r > 120 && c.r < 136 && c.g == 0 && c.b > 120 && c.b < 136);
  SDL_DestroySurface(src);
  SDL_DestroySurface(dst);
  return 0;
}

/* The colour's RGB tints the image. */
static int colour_tints_image(void) {
  const Uint8 rgba[] = { 255, 255, 255, 255,  255, 255, 255, 255 };
  SDL_Surface *src = image(2, 1, rgba);
  SDL_Surface *dst = screen(8, 4, 0, 0, 0);
  CHECK(image_scale_blit(src, dst, 0, 0, 8, 4, (SDL_Color){ 255, 128, 0, 255 }));
  SDL_Color c = pixel(dst, 4, 2);
  CHECK(c.r == 255 && c.g > 120 && c.g < 136 && c.b == 0);
  SDL_DestroySurface(src);
  SDL_DestroySurface(dst);
  return 0;
}

int main(void) {
  int failures = 0;
  failures += colour_tints_image();
  failures += translucent_image_blends();
  failures += deep_zoom_draws_visible_part();
  failures += clipped_draws_join_without_seams();
  failures += transparent_neighbour_keeps_edge_colour();
  failures += colour_alpha_sets_opacity();
  return failures ? 1 : 0;
}
