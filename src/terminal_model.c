#include "terminal_model.h"
#include <string.h>

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

bool anvil_terminal_model_new(GhosttyTerminal *model, uint16_t cols, uint16_t rows,
                              uint32_t cell_width, uint32_t cell_height,
                              const size_t *scrollback_lines) {
  if (ghostty_terminal_new(&terminal_allocator, model, cols, rows) != GHOSTTY_SUCCESS) return false;
  size_t max_bytes = 64u * 1024u * 1024u;
  if (scrollback_lines && (
      ghostty_terminal_set(*model, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &max_bytes) != GHOSTTY_SUCCESS ||
      ghostty_terminal_set(*model, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, scrollback_lines) != GHOSTTY_SUCCESS)) return false;
  /* Pi's OSC 133 A marker must not move the cursor during synchronized repaint. */
  bool fresh_line = false;
  if (ghostty_terminal_set(*model,
      GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT_FRESH_LINE_IN_SYNCHRONIZED_OUTPUT,
      &fresh_line) != GHOSTTY_SUCCESS) return false;
  return ghostty_terminal_resize(*model, cols, rows, cell_width, cell_height) == GHOSTTY_SUCCESS;
}

void anvil_terminal_replay_free(AnvilTerminalReplay *replay) {
  if (replay->bytes) HeapFree(GetProcessHeap(), 0, replay->bytes);
  replay->bytes = NULL;
  replay->length = 0;
}

void anvil_terminal_replay_append(AnvilTerminalReplay *replay, const uint8_t *bytes, size_t length) {
  if (replay->overflow) return;
  if (length > ANVIL_TERMINAL_REPLAY_LIMIT - replay->length) {
    replay->overflow = true;
    anvil_terminal_replay_free(replay);
    return;
  }
  if (!replay->bytes) replay->bytes = HeapAlloc(GetProcessHeap(), 0, ANVIL_TERMINAL_REPLAY_LIMIT);
  if (!replay->bytes) { replay->overflow = true; return; }
  memcpy(replay->bytes + replay->length, bytes, length);
  replay->length += length;
}
