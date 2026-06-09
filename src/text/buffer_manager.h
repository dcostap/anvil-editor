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

typedef struct BatchCursorMapping {
  unsigned int cursor_index;
  size_t old_start_offset;
  size_t old_end_offset;
  size_t new_start_offset;
  size_t new_end_offset;
  size_t new_cursor_offset;
} BatchCursorMapping;

typedef struct BatchEditResult {
  bool applied;
  bool rejected;
  size_t edit_count;
  size_t changed_start;
  size_t changed_old_end;
  size_t changed_new_end;
  size_t changed_old_start_line;
  size_t changed_old_end_line;
  size_t changed_new_start_line;
  size_t changed_new_end_line;
  BatchCursorMapping *cursor_mappings;
  size_t cursor_mapping_count;
} BatchEditResult;

void buffer_manager_init(BufferManager *manager, Buffer *buffer);
bool buffer_manager_update_undo(BufferManager *manager, size_t op_offset);
bool buffer_manager_snap_to(BufferManager *manager, UndoRedoNode *target, size_t *op_offset_out);

BatchEditResult buffer_manager_apply_edits(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count
);
void batch_edit_result_dispose(BatchEditResult *result);

#endif
