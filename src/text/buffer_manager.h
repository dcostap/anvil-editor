#ifndef ANVIL_TEXT_BUFFER_MANAGER_H
#define ANVIL_TEXT_BUFFER_MANAGER_H

#include "text/buffer.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct BufferManager {
  Buffer *buffer;
} BufferManager;

typedef struct BatchEditItem {
  size_t start_offset;
  size_t end_offset;
  const char *text;
  size_t text_len;
  unsigned int cursor_index;
} BatchEditItem;

typedef struct BatchEditResult {
  bool applied;
  bool rejected;
  size_t edit_count;
  size_t changed_start;
  size_t changed_old_end;
  size_t changed_new_end;
} BatchEditResult;

void buffer_manager_init(BufferManager *manager, Buffer *buffer);

BatchEditResult buffer_manager_apply_edits(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count
);

#endif
