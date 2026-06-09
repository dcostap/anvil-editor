#ifndef ANVIL_TEXT_BUFFER_MANAGER_H
#define ANVIL_TEXT_BUFFER_MANAGER_H

#include "text/buffer.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct BufferManagerListener BufferManagerListener;

typedef struct BufferManager {
  Buffer *buffer;
  BufferManagerListener *listeners;
  size_t listener_count;
  size_t listener_capacity;
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

typedef struct BatchEditPoint {
  size_t line;
  size_t col;
} BatchEditPoint;

typedef struct BatchEditDescriptor {
  unsigned int cursor_index;
  size_t old_start_offset;
  size_t old_end_offset;
  size_t new_start_offset;
  size_t new_end_offset;
  BatchEditPoint old_start_point;
  BatchEditPoint old_end_point;
  BatchEditPoint new_start_point;
  BatchEditPoint new_end_point;
} BatchEditDescriptor;

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
  BatchEditDescriptor *edit_descriptors;
  size_t edit_descriptor_count;
} BatchEditResult;

typedef struct BufferSnapResult {
  bool applied;
  bool rejected;
  size_t old_len;
  size_t new_len;
  size_t changed_start;
  size_t changed_old_end;
  size_t changed_new_end;
  size_t op_offset;
} BufferSnapResult;

typedef void (*BufferManagerEditCallback)(void *user, const BatchEditResult *result, void *source);
typedef void (*BufferManagerSnapCallback)(void *user, const BufferSnapResult *result, void *source);

struct BufferManagerListener {
  void *user;
  BufferManagerEditCallback on_edit;
  BufferManagerSnapCallback on_snap;
};

void buffer_manager_init(BufferManager *manager, Buffer *buffer);
void buffer_manager_dispose(BufferManager *manager);
bool buffer_manager_register_listener(
  BufferManager *manager,
  void *user,
  BufferManagerEditCallback on_edit,
  BufferManagerSnapCallback on_snap
);
void buffer_manager_unregister_listener(BufferManager *manager, void *user);
bool buffer_manager_update_undo(BufferManager *manager, size_t op_offset);
bool buffer_manager_snap_to(BufferManager *manager, UndoRedoNode *target, size_t *op_offset_out);
bool buffer_manager_snap_to_from(BufferManager *manager, UndoRedoNode *target, size_t *op_offset_out, void *source);
bool buffer_manager_undo_from(BufferManager *manager, size_t *op_offset_out, void *source);
bool buffer_manager_redo_from(BufferManager *manager, size_t *op_offset_out, void *source);

BatchEditResult buffer_manager_apply_edits(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count
);
BatchEditResult buffer_manager_apply_edits_from(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count,
  void *source
);
BatchEditResult buffer_manager_apply_edits_update_undo_from(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count,
  size_t op_offset,
  void *source
);
void batch_edit_result_dispose(BatchEditResult *result);

#endif
