#include "image_decode.h"

#include <stdio.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)

/* Writes `size` bytes to a temporary file and returns its path. */
static char *write_file(const char *name, const void *bytes, size_t size) {
  char *path = NULL;
  const char *temp = SDL_getenv("TEMP");
  SDL_asprintf(&path, "%s/anvil-image-decode-%s", temp ? temp : ".", name);
  return SDL_SaveFile(path, bytes, size) ? path : NULL;
}

/* Decodes `path` for a `width` x `height` backdrop and expects an error. */
static int expect_error(const char *path, int width, int height) {
  char *error = NULL;
  int covers_width = -1, covers_height = -1;
  SDL_Surface *image = anvil_image_decode_jpeg(path, width, height, &covers_width, &covers_height, &error);
  CHECK(image == NULL);
  CHECK(error != NULL && error[0] != '\0');
  SDL_free(error);
  return 0;
}

int main(int argc, char **argv) {
  CHECK(argc == 2);
  size_t size = 0;
  unsigned char *jpeg = SDL_LoadFile(argv[1], &size);
  CHECK(jpeg != NULL && size > 1000);
  char *error = NULL;
  int covers_width = -1, covers_height = -1;

  /* A full-size backdrop gets the whole image, and no larger backdrop needs another decode. */
  SDL_Surface *full = anvil_image_decode_jpeg(argv[1], 0, 0, &covers_width, &covers_height, &error);
  CHECK(full != NULL && error == NULL);
  CHECK(full->format == SDL_PIXELFORMAT_RGBA32);
  CHECK(covers_width == 0 && covers_height == 0);

  /* A quarter-size backdrop gets a smaller image that still covers most of it, and reports what it covers. */
  int width = full->w / 4, height = full->h / 4;
  SDL_Surface *small = anvil_image_decode_jpeg(argv[1], width, height, &covers_width, &covers_height, &error);
  CHECK(small != NULL && error == NULL);
  CHECK(small->w < full->w && small->w >= width * 8 / 10 && small->h >= height * 8 / 10);
  CHECK(covers_width >= width && covers_height >= height && covers_width < full->w);
  /* A tall backdrop needs the image's height, so it gets a larger image than its width alone needs. */
  SDL_Surface *tall = anvil_image_decode_jpeg(argv[1], width / 4, full->h, &covers_width, &covers_height, &error);
  CHECK(tall != NULL && tall->h >= full->h * 8 / 10);
  SDL_DestroySurface(tall);
  SDL_DestroySurface(small);

  /* A truncated file still gives an image of the full size, as other decoders show a partial image. */
  char *truncated = write_file("truncated.jpg", jpeg, size / 2);
  CHECK(truncated != NULL);
  SDL_Surface *partial = anvil_image_decode_jpeg(truncated, 0, 0, &covers_width, &covers_height, &error);
  CHECK(partial != NULL && partial->w == full->w && partial->h == full->h);
  SDL_DestroySurface(partial);
  SDL_DestroySurface(full);

  /* Missing, empty, cut-off and non-JPEG files give an error, not a crash. */
  char *empty = write_file("empty.jpg", "", 0);
  char *header = write_file("header.jpg", jpeg, 64);
  char *text = write_file("text.jpg", "not an image", 12);
  CHECK(empty && header && text);
  if (expect_error("missing-anvil-image.jpg", 100, 100)) return 1;
  if (expect_error(empty, 100, 100)) return 1;
  if (expect_error(header, 100, 100)) return 1;
  if (expect_error(text, 100, 100)) return 1;
  for (char *path_list[] = {truncated, empty, header, text}, **p = path_list; p < path_list + 4; p++) {
    SDL_RemovePath(*p);
    SDL_free(*p);
  }
  SDL_free(jpeg);
  return 0;
}
