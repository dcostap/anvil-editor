#include "image_decode.h"

#include <setjmp.h>
#include <stdio.h>
#include <jpeglib.h>

/* A decoded image may be this much smaller than its drawn size. Wallpapers show behind a tint, where a slight
   upscale is not visible, and the next larger scale costs four times the pixels. */
#define MIN_COVERAGE 0.8

typedef struct DecodeError {
  struct jpeg_error_mgr manager;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
} DecodeError;

static void stop_decode(j_common_ptr info) {
  DecodeError *error = (DecodeError *)info->err;
  info->err->format_message(info, error->message);
  longjmp(error->jump, 1);
}

/* Warnings, such as for a truncated file, still decode an image. libjpeg would print them. */
static void ignore_message(j_common_ptr info) {
  (void)info;
}

/* libjpeg-turbo has SIMD code only for scales 1/1, 1/2, 1/4 and 1/8. Other scales decode slower than the full
   image. Returns the denominator of the smallest scale that keeps enough pixels. */
static unsigned int scale_denominator(int width, int height, int full_width, int full_height) {
  if (width <= 0 || height <= 0) return 1;
  double cover = SDL_max((double)width / full_width, (double)height / full_height);
  for (unsigned int denominator = 8; denominator > 1; denominator /= 2) {
    if (1.0 / denominator >= cover * MIN_COVERAGE) return denominator;
  }
  return 1;
}

SDL_Surface *anvil_image_decode_jpeg(const char *path, int width, int height,
  int *covers_width, int *covers_height, char **error) {
  *error = NULL;
  size_t size = 0;
  unsigned char *bytes = SDL_LoadFile(path, &size);
  if (!bytes) {
    *error = SDL_strdup(SDL_GetError());
    return NULL;
  }
  struct jpeg_decompress_struct info;
  DecodeError failure;
  info.err = jpeg_std_error(&failure.manager);
  failure.manager.error_exit = stop_decode;
  failure.manager.output_message = ignore_message;
  SDL_Surface *volatile surface = NULL;
  if (setjmp(failure.jump)) {
    jpeg_destroy_decompress(&info);
    SDL_DestroySurface(surface);
    SDL_free(bytes);
    *error = SDL_strdup(failure.message);
    return NULL;
  }
  jpeg_create_decompress(&info);
  jpeg_mem_src(&info, bytes, (unsigned long)size);
  jpeg_read_header(&info, TRUE);
  info.scale_num = 1;
  info.scale_denom = scale_denominator(width, height, (int)info.image_width, (int)info.image_height);
  info.dct_method = JDCT_IFAST;
  info.out_color_space = JCS_EXT_RGBA;
  jpeg_start_decompress(&info);
  surface = SDL_CreateSurface((int)info.output_width, (int)info.output_height, SDL_PIXELFORMAT_RGBA32);
  if (!surface) {
    *error = SDL_strdup(SDL_GetError());
    jpeg_destroy_decompress(&info);
    SDL_free(bytes);
    return NULL;
  }
  unsigned char *pixels = surface->pixels;
  while (info.output_scanline < info.output_height) {
    JSAMPROW rows[16];
    JDIMENSION count = SDL_min(16, info.output_height - info.output_scanline);
    for (JDIMENSION i = 0; i < count; i++) {
      rows[i] = pixels + (size_t)surface->pitch * (info.output_scanline + i);
    }
    jpeg_read_scanlines(&info, rows, count);
  }
  *covers_width = *covers_height = 0;
  if (info.scale_denom > 1) {
    *covers_width = (int)(info.image_width / (info.scale_denom * MIN_COVERAGE));
    *covers_height = (int)(info.image_height / (info.scale_denom * MIN_COVERAGE));
  }
  jpeg_finish_decompress(&info);
  jpeg_destroy_decompress(&info);
  SDL_free(bytes);
  return surface;
}
