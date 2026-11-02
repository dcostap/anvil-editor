#ifndef ANVIL_IMAGE_DECODE_H
#define ANVIL_IMAGE_DECODE_H

#include <SDL3/SDL.h>

/* Decodes the JPEG file at `path` into a new RGBA32 surface with libjpeg-turbo. A `width` and `height` above 0 name the size that
   the image covers when it is drawn. The decoder then uses the smallest DCT scale that keeps enough pixels for
   that size, which is faster and uses less memory. `covers_width` and `covers_height` get the largest drawn
   size that the result serves, or 0 when no larger scale exists. Returns NULL and sets `*error` (free it with
   SDL_free) when the file cannot be read or decoded. */
SDL_Surface *anvil_image_decode_jpeg(const char *path, int width, int height,
  int *covers_width, int *covers_height, char **error);

#endif
