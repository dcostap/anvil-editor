#include "terminal_model.h"
#include <stdlib.h>
#include <string.h>
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>

/* Bound decoded pixels before SDL allocates a surface. File and shared-memory
 * image transfers remain disabled; only bytes from the terminal are decoded. */
#define TERMINAL_IMAGE_LIMIT (32u * 1024u * 1024u)

static uint32_t png_u32(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static bool terminal_decode_png(void *userdata, const GhosttyAllocator *allocator,
    const uint8_t *data, size_t length, GhosttySysImage *out) {
  (void)userdata;
  if (length < 24 || memcmp(data, "\x89PNG\r\n\x1a\n", 8) ||
      png_u32(data + 8) != 13 || memcmp(data + 12, "IHDR", 4)) return false;
  uint32_t width = png_u32(data + 16), height = png_u32(data + 20);
  if (!width || !height || width > TERMINAL_IMAGE_LIMIT / 4 / height) return false;
  SDL_IOStream *stream = SDL_IOFromConstMem(data, length);
  if (!stream) return false;
  SDL_Surface *decoded = IMG_LoadPNG_IO(stream);
  SDL_CloseIO(stream);
  if (!decoded) return false;
  SDL_Surface *rgba = SDL_ConvertSurface(decoded, SDL_PIXELFORMAT_RGBA32);
  SDL_DestroySurface(decoded);
  if (!rgba) return false;
  if ((uint32_t)rgba->w != width || (uint32_t)rgba->h != height) {
    SDL_DestroySurface(rgba);
    return false;
  }
  size_t bytes = (size_t)width * height * 4;
  uint8_t *pixels = ghostty_alloc(allocator, bytes);
  if (pixels) {
    for (uint32_t y = 0; y < height; y++)
      memcpy(pixels + (size_t)y * width * 4,
        (uint8_t *)rgba->pixels + (size_t)y * rgba->pitch, (size_t)width * 4);
    *out = (GhosttySysImage){ .width = width, .height = height, .data = pixels, .data_len = bytes };
  }
  SDL_DestroySurface(rgba);
  return pixels != NULL;
}

static BOOL CALLBACK init_terminal_images(PINIT_ONCE once, PVOID param, PVOID *context) {
  (void)once; (void)param; (void)context;
  return ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void *)terminal_decode_png) == GHOSTTY_SUCCESS;
}

static bool terminal_images_init(void) {
  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
  return InitOnceExecuteOnce(&once, init_terminal_images, NULL, NULL) != 0;
}

static void *terminal_alloc(
  void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr
) {
  (void)ctx;
  (void)alignment;
  (void)ret_addr;
  return HeapAlloc(GetProcessHeap(), 0, len);
}

static bool terminal_resize(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  size_t new_len, uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory;
  (void)alignment;
  (void)ret_addr;
  return new_len <= memory_len;
}

static void *terminal_remap(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  size_t new_len, uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory_len;
  (void)alignment;
  (void)ret_addr;
  return HeapReAlloc(GetProcessHeap(), 0, memory, new_len);
}

static void terminal_free(
  void *ctx, void *memory, size_t memory_len, uint8_t alignment,
  uintptr_t ret_addr
) {
  (void)ctx;
  (void)memory_len;
  (void)alignment;
  (void)ret_addr;
  if (memory) HeapFree(GetProcessHeap(), 0, memory);
}

static const GhosttyAllocatorVtable terminal_allocator_vtable = {
  .alloc = terminal_alloc,
  .resize = terminal_resize,
  .remap = terminal_remap,
  .free = terminal_free,
};

const GhosttyAllocator terminal_allocator = {
  .ctx = NULL,
  .vtable = &terminal_allocator_vtable,
};

bool anvil_terminal_model_options(GhosttyTerminal model, const size_t *scrollback_lines) {
  /* ConPTY owns the live screen. Pulling saved history into it on growth moves
     the visible prompt without moving the shell's input coordinates. */
  bool pull_scrollback = false;
  if (ghostty_terminal_set(model, GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK,
      &pull_scrollback) != GHOSTTY_SUCCESS) return false;
  uint64_t image_limit = TERMINAL_IMAGE_LIMIT;
  if (!terminal_images_init() || ghostty_terminal_set(model,
      GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_limit) != GHOSTTY_SUCCESS) return false;
  size_t max_bytes = 64u * 1024u * 1024u;
  if (scrollback_lines && (
      ghostty_terminal_set(model, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &max_bytes) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(model, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, scrollback_lines) != GHOSTTY_SUCCESS)) return false;
  /* Pi's OSC 133 A marker must not move the cursor during synchronized repaint. */
  bool fresh_line = false;
  if (ghostty_terminal_set(model,
      GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT_FRESH_LINE_IN_SYNCHRONIZED_OUTPUT,
      &fresh_line) != GHOSTTY_SUCCESS) return false;
  size_t continuation = ANVIL_TERMINAL_CONTINUATION_LIMIT;
  return ghostty_terminal_set(model, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
    &continuation) == GHOSTTY_SUCCESS;
}

bool anvil_terminal_model_new(GhosttyTerminal *model, uint16_t cols, uint16_t rows,
                              uint32_t cell_width, uint32_t cell_height,
                              const size_t *scrollback_lines) {
  return terminal_images_init() &&
    ghostty_terminal_new(&terminal_allocator, model, cols, rows) == GHOSTTY_SUCCESS &&
    anvil_terminal_model_options(*model, scrollback_lines) &&
    ghostty_terminal_resize(*model, cols, rows, cell_width, cell_height) == GHOSTTY_SUCCESS;
}

typedef struct { uint8_t *bytes; size_t length, capacity, limit; } SnapshotBuffer;

static bool snapshot_write(void *userdata, const uint8_t *bytes, size_t length) {
  SnapshotBuffer *buffer = userdata;
  if (length > buffer->limit - buffer->length) return false;
  size_t required = buffer->length + length;
  if (required > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity : 65536;
    while (capacity < required) capacity *= 2;
    uint8_t *next = realloc(buffer->bytes, capacity);
    if (!next) return false;
    buffer->bytes = next; buffer->capacity = capacity;
  }
  memcpy(buffer->bytes + buffer->length, bytes, length);
  buffer->length += length;
  return true;
}

static bool encode_limit(GhosttyTerminal model, uint8_t **bytes, size_t *length, size_t limit) {
  SnapshotBuffer buffer = { .limit = limit };
  *bytes = NULL; *length = 0;
  if (ghostty_snapshot_encode(model, (GhosttyWriter){ snapshot_write, &buffer }) != GHOSTTY_SUCCESS) {
    free(buffer.bytes); return false;
  }
  *bytes = buffer.bytes; *length = buffer.length;
  return true;
}

bool anvil_terminal_snapshot_encode(GhosttyTerminal model, uint8_t **bytes, size_t *length) {
  return encode_limit(model, bytes, length, ANVIL_TERMINAL_SNAPSHOT_LIMIT);
}

bool anvil_terminal_snapshot_decode(const uint8_t *bytes, size_t length, GhosttyTerminal *model) {
  GhosttySnapshotDecoder decoder = NULL;
  *model = NULL;
  size_t consumed = 0;
  bool ok = length <= ANVIL_TERMINAL_SNAPSHOT_LIMIT &&
    ghostty_snapshot_decoder_new_buf(&terminal_allocator, &decoder, bytes, length) == GHOSTTY_SUCCESS &&
    ghostty_snapshot_decoder_decode(decoder, model) == GHOSTTY_SUCCESS &&
    ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed) == GHOSTTY_SUCCESS &&
    consumed == length;
  ghostty_snapshot_decoder_free(decoder);
  if (!ok && *model) { ghostty_terminal_free(*model); *model = NULL; }
  return ok;
}

bool anvil_terminal_disk_snapshot_prepare(uint8_t **bytes, size_t *length, GhosttyTerminal *decoded) {
  if (decoded) *decoded = NULL;
  GhosttyTerminal copy = NULL;
  bool ok = anvil_terminal_snapshot_decode(*bytes, *length, &copy);
  size_t continuation = ANVIL_TERMINAL_CONTINUATION_LIMIT;
  ok = ok && ghostty_terminal_set(copy, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation) == GHOSTTY_SUCCESS;
  if (ok && *length > ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT) {
    size_t budget = 0;
    ok = ghostty_terminal_get(copy, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &budget) == GHOSTTY_SUCCESS;
    uint8_t *trimmed = NULL; size_t count = 0;
    for (budget /= 2; ok; budget /= 2) {
      ok = ghostty_terminal_set(copy, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &budget) == GHOSTTY_SUCCESS;
      if (ok && encode_limit(copy, &trimmed, &count, ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT)) break;
      if (!budget) { ok = false; break; }
    }
    if (ok) { free(*bytes); *bytes = trimmed; *length = count; }
  }
  if (ok && decoded) *decoded = copy;
  else if (copy) ghostty_terminal_free(copy);
  return ok;
}
