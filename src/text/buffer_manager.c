#include "text/buffer_manager.h"

#include <stdlib.h>
#include <string.h>

typedef struct SortedBatchEditItem {
  BatchEditItem edit;
  size_t original_index;
} SortedBatchEditItem;

static int compare_batch_edit_items(const void *a, const void *b) {
  const SortedBatchEditItem *ea = (const SortedBatchEditItem *) a;
  const SortedBatchEditItem *eb = (const SortedBatchEditItem *) b;
  if (ea->edit.start_offset < eb->edit.start_offset) return -1;
  if (ea->edit.start_offset > eb->edit.start_offset) return 1;
  if (ea->edit.end_offset < eb->edit.end_offset) return -1;
  if (ea->edit.end_offset > eb->edit.end_offset) return 1;
  if (ea->original_index < eb->original_index) return -1;
  if (ea->original_index > eb->original_index) return 1;
  return 0;
}

static BatchEditResult rejected_result(size_t edit_count) {
  BatchEditResult result;
  memset(&result, 0, sizeof(result));
  result.rejected = true;
  result.edit_count = edit_count;
  return result;
}

static BufferSnapResult rejected_snap_result(void) {
  BufferSnapResult result;
  memset(&result, 0, sizeof(result));
  result.rejected = true;
  return result;
}

void batch_edit_result_dispose(BatchEditResult *result) {
  if (!result) return;
  free(result->cursor_mappings);
  result->cursor_mappings = NULL;
  result->cursor_mapping_count = 0;
  free(result->edit_descriptors);
  result->edit_descriptors = NULL;
  result->edit_descriptor_count = 0;
}

static bool point_for_offset(const Buffer *buffer, size_t offset, BatchEditPoint *out) {
  if (!buffer || !out) return false;
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(buffer, offset, &lc)) return false;
  out->line = lc.line;
  out->col = lc.col;
  return true;
}

static bool changed_line_range(
  const Buffer *buffer,
  size_t start_offset,
  size_t end_offset,
  bool changed,
  size_t *start_line_out,
  size_t *end_line_out
) {
  if (!buffer || !start_line_out || !end_line_out) return false;
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(buffer, start_offset, &lc)) return false;
  *start_line_out = lc.line;

  if (!changed) {
    *end_line_out = lc.line;
    return true;
  }

  if (end_offset > start_offset) {
    if (!buffer_offset_to_line_col(buffer, end_offset - 1, &lc)) return false;
    *end_line_out = lc.line + 1;
  } else {
    *end_line_out = *start_line_out + 1;
  }
  return true;
}

void buffer_manager_init(BufferManager *manager, Buffer *buffer) {
  if (!manager) return;
  memset(manager, 0, sizeof(*manager));
  manager->buffer = buffer;
}

void buffer_manager_dispose(BufferManager *manager) {
  if (!manager) return;
  free(manager->listeners);
  memset(manager, 0, sizeof(*manager));
}

bool buffer_manager_register_listener(
  BufferManager *manager,
  void *user,
  BufferManagerEditCallback on_edit,
  BufferManagerSnapCallback on_snap
) {
  if (!manager || !user || (!on_edit && !on_snap)) return false;
  for (size_t i = 0; i < manager->listener_count; ++i) {
    if (manager->listeners[i].user == user) {
      manager->listeners[i].on_edit = on_edit;
      manager->listeners[i].on_snap = on_snap;
      return true;
    }
  }
  if (manager->listener_count == manager->listener_capacity) {
    size_t cap = manager->listener_capacity ? manager->listener_capacity * 2 : 4;
    BufferManagerListener *listeners = (BufferManagerListener *) realloc(manager->listeners, cap * sizeof(BufferManagerListener));
    if (!listeners) return false;
    manager->listeners = listeners;
    manager->listener_capacity = cap;
  }
  manager->listeners[manager->listener_count].user = user;
  manager->listeners[manager->listener_count].on_edit = on_edit;
  manager->listeners[manager->listener_count].on_snap = on_snap;
  manager->listener_count += 1;
  return true;
}

void buffer_manager_unregister_listener(BufferManager *manager, void *user) {
  if (!manager || !user) return;
  size_t out = 0;
  for (size_t i = 0; i < manager->listener_count; ++i) {
    if (manager->listeners[i].user != user) {
      manager->listeners[out++] = manager->listeners[i];
    }
  }
  manager->listener_count = out;
}

static void notify_edit(BufferManager *manager, const BatchEditResult *result, void *source) {
  if (!manager || !result || !result->applied) return;
  for (size_t i = 0; i < manager->listener_count; ++i) {
    if (manager->listeners[i].on_edit) manager->listeners[i].on_edit(manager->listeners[i].user, result, source);
  }
}

static void notify_snap(BufferManager *manager, const BufferSnapResult *result, void *source) {
  if (!manager || !result || !result->applied) return;
  for (size_t i = 0; i < manager->listener_count; ++i) {
    if (manager->listeners[i].on_snap) manager->listeners[i].on_snap(manager->listeners[i].user, result, source);
  }
}

bool buffer_manager_update_undo(BufferManager *manager, size_t op_offset) {
  return manager && manager->buffer && buffer_update_undo(manager->buffer, op_offset);
}

static BufferSnapResult buffer_manager_make_snap_result(
  BufferManager *manager,
  UndoRedoNode *target,
  size_t *op_offset_out,
  void *source
) {
  if (!manager || !manager->buffer || !target) return rejected_snap_result();

  UndoRedoNode *undo_before = manager->buffer->has_undo_graph ? manager->buffer->undo_graph.current : NULL;

  size_t old_len = 0;
  char *old_text = buffer_to_string(manager->buffer, &old_len);
  if (!old_text) return rejected_snap_result();

  size_t op_offset = 0;
  if (!buffer_snap_to_undo_node(manager->buffer, target, &op_offset)) {
    free(old_text);
    return rejected_snap_result();
  }

  size_t new_len = 0;
  char *new_text = buffer_to_string(manager->buffer, &new_len);
  if (!new_text) {
    free(old_text);
    return rejected_snap_result();
  }

  size_t prefix = 0;
  while (prefix < old_len && prefix < new_len && old_text[prefix] == new_text[prefix]) ++prefix;

  size_t suffix = 0;
  while (suffix < old_len - prefix && suffix < new_len - prefix &&
         old_text[old_len - 1 - suffix] == new_text[new_len - 1 - suffix]) {
    ++suffix;
  }

  BufferSnapResult result;
  memset(&result, 0, sizeof(result));
  result.applied = true;
  result.undo_node_before = undo_before;
  result.undo_node_after = manager->buffer->has_undo_graph ? manager->buffer->undo_graph.current : NULL;
  result.old_len = old_len;
  result.new_len = new_len;
  result.changed_start = prefix;
  result.changed_old_end = old_len - suffix;
  result.changed_new_end = new_len - suffix;
  result.op_offset = op_offset;

  if (op_offset_out) *op_offset_out = op_offset;
  notify_snap(manager, &result, source);
  free(old_text);
  free(new_text);
  return result;
}

bool buffer_manager_snap_to(BufferManager *manager, UndoRedoNode *target, size_t *op_offset_out) {
  return buffer_manager_snap_to_from(manager, target, op_offset_out, NULL);
}

bool buffer_manager_snap_to_from(BufferManager *manager, UndoRedoNode *target, size_t *op_offset_out, void *source) {
  BufferSnapResult result = buffer_manager_make_snap_result(manager, target, op_offset_out, source);
  return result.applied;
}

bool buffer_manager_undo_from(BufferManager *manager, size_t *op_offset_out, void *source) {
  if (!manager || !manager->buffer || !manager->buffer->has_undo_graph) return false;
  UndoRedoGraph *graph = &manager->buffer->undo_graph;
  if (!undo_graph_can_undo(graph)) return false;
  return buffer_manager_snap_to_from(manager, graph->current->parent, op_offset_out, source);
}

bool buffer_manager_redo_from(BufferManager *manager, size_t *op_offset_out, void *source) {
  if (!manager || !manager->buffer || !manager->buffer->has_undo_graph) return false;
  UndoRedoGraph *graph = &manager->buffer->undo_graph;
  if (!undo_graph_can_redo(graph)) return false;
  return buffer_manager_snap_to_from(manager, graph->current->last_child, op_offset_out, source);
}

typedef enum ApplyUndoMode {
  APPLY_UNDO_COMMIT,
  APPLY_UNDO_UPDATE_CURRENT,
} ApplyUndoMode;

static BatchEditResult buffer_manager_apply_edits_internal(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count,
  void *source,
  ApplyUndoMode undo_mode,
  size_t op_offset
) {
  BatchEditResult result;
  memset(&result, 0, sizeof(result));
  result.edit_count = edit_count;

  if (!manager || !manager->buffer) return rejected_result(edit_count);
  result.undo_node_before = manager->buffer->has_undo_graph ? manager->buffer->undo_graph.current : NULL;
  result.undo_node_after = result.undo_node_before;
  if (edit_count == 0) {
    result.applied = true;
    result.changed_start = buffer_len(manager->buffer);
    result.changed_old_end = result.changed_start;
    result.changed_new_end = result.changed_start;
    if (!changed_line_range(manager->buffer, result.changed_start, result.changed_start, false,
                            &result.changed_old_start_line, &result.changed_old_end_line)) {
      return rejected_result(edit_count);
    }
    result.changed_new_start_line = result.changed_old_start_line;
    result.changed_new_end_line = result.changed_old_end_line;
    return result;
  }
  if (!edits) return rejected_result(edit_count);

  SortedBatchEditItem *sorted = (SortedBatchEditItem *) malloc(sizeof(SortedBatchEditItem) * edit_count);
  if (!sorted) return rejected_result(edit_count);

  size_t original_len = buffer_len(manager->buffer);
  for (size_t i = 0; i < edit_count; ++i) {
    BatchEditItem edit = edits[i];
    if (edit.start_offset > edit.end_offset || edit.end_offset > original_len) {
      free(sorted);
      return rejected_result(edit_count);
    }
    if (edit.text_len > 0 && !edit.text) {
      free(sorted);
      return rejected_result(edit_count);
    }
    sorted[i].edit = edit;
    sorted[i].original_index = i;
  }

  qsort(sorted, edit_count, sizeof(SortedBatchEditItem), compare_batch_edit_items);

  for (size_t i = 1; i < edit_count; ++i) {
    BatchEditItem prev = sorted[i - 1].edit;
    BatchEditItem cur = sorted[i].edit;
    if (cur.start_offset < prev.end_offset) {
      free(sorted);
      return rejected_result(edit_count);
    }
    if (cur.start_offset == prev.start_offset && cur.end_offset == prev.end_offset) {
      free(sorted);
      return rejected_result(edit_count);
    }
  }

  size_t changed_start = sorted[0].edit.start_offset;
  size_t changed_old_end = sorted[0].edit.end_offset;
  size_t removed_total = 0;
  size_t inserted_total = 0;
  bool changed = false;

  for (size_t i = 0; i < edit_count; ++i) {
    BatchEditItem edit = sorted[i].edit;
    if (edit.start_offset < changed_start) changed_start = edit.start_offset;
    if (edit.end_offset > changed_old_end) changed_old_end = edit.end_offset;
    removed_total += edit.end_offset - edit.start_offset;
    inserted_total += edit.text_len;
    changed = changed || edit.start_offset != edit.end_offset || edit.text_len != 0;
  }

  size_t changed_new_end = changed
    ? changed_old_end - removed_total + inserted_total
    : original_len;

  BatchCursorMapping *cursor_mappings = NULL;
  BatchEditDescriptor *edit_descriptors = NULL;
  if (edit_count > 0) {
    cursor_mappings = (BatchCursorMapping *) calloc(edit_count, sizeof(BatchCursorMapping));
    edit_descriptors = (BatchEditDescriptor *) calloc(edit_count, sizeof(BatchEditDescriptor));
    if (!cursor_mappings || !edit_descriptors) {
      free(edit_descriptors);
      free(cursor_mappings);
      free(sorted);
      return rejected_result(edit_count);
    }
    size_t removed_before = 0;
    size_t inserted_before = 0;
    for (size_t i = 0; i < edit_count; ++i) {
      BatchEditItem edit = sorted[i].edit;
      size_t original_index = sorted[i].original_index;
      size_t new_start = edit.start_offset - removed_before + inserted_before;
      size_t new_end = new_start + edit.text_len;
      cursor_mappings[original_index].cursor_index = edit.cursor_index;
      cursor_mappings[original_index].old_start_offset = edit.start_offset;
      cursor_mappings[original_index].old_end_offset = edit.end_offset;
      cursor_mappings[original_index].new_start_offset = new_start;
      cursor_mappings[original_index].new_end_offset = new_end;
      cursor_mappings[original_index].new_cursor_offset = new_end;

      edit_descriptors[original_index].cursor_index = edit.cursor_index;
      edit_descriptors[original_index].old_start_offset = edit.start_offset;
      edit_descriptors[original_index].old_end_offset = edit.end_offset;
      edit_descriptors[original_index].new_start_offset = new_start;
      edit_descriptors[original_index].new_end_offset = new_end;
      if (!point_for_offset(manager->buffer, edit.start_offset, &edit_descriptors[original_index].old_start_point) ||
          !point_for_offset(manager->buffer, edit.end_offset, &edit_descriptors[original_index].old_end_point)) {
        free(edit_descriptors);
        free(cursor_mappings);
        free(sorted);
        return rejected_result(edit_count);
      }

      removed_before += edit.end_offset - edit.start_offset;
      inserted_before += edit.text_len;
    }
  }

  size_t changed_old_start_line = 0;
  size_t changed_old_end_line = 0;
  if (!changed_line_range(manager->buffer, changed ? changed_start : original_len,
                          changed ? changed_old_end : original_len, changed,
                          &changed_old_start_line, &changed_old_end_line)) {
    free(edit_descriptors);
    free(cursor_mappings);
    free(sorted);
    return rejected_result(edit_count);
  }

  PieceTreeSnapshot before = piece_tree_snapshot_acquire(&manager->buffer->tree);
  for (size_t i = edit_count; i > 0; --i) {
    BatchEditItem edit = sorted[i - 1].edit;
    size_t remove_len = edit.end_offset - edit.start_offset;
    if (remove_len > 0 && !piece_tree_remove(&manager->buffer->tree, edit.start_offset, remove_len)) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(edit_descriptors);
      free(cursor_mappings);
      free(sorted);
      return rejected_result(edit_count);
    }
    if (edit.text_len > 0 && !piece_tree_insert(&manager->buffer->tree, edit.start_offset, edit.text, edit.text_len)) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(edit_descriptors);
      free(cursor_mappings);
      free(sorted);
      return rejected_result(edit_count);
    }
  }

  size_t changed_new_start_line = 0;
  size_t changed_new_end_line = 0;
  if (!changed_line_range(manager->buffer, changed ? changed_start : original_len,
                          changed_new_end, changed,
                          &changed_new_start_line, &changed_new_end_line)) {
    piece_tree_restore_snapshot(&manager->buffer->tree, &before);
    piece_tree_snapshot_release(&before);
    free(edit_descriptors);
    free(cursor_mappings);
    free(sorted);
    return rejected_result(edit_count);
  }

  for (size_t i = 0; i < edit_count; ++i) {
    if (!point_for_offset(manager->buffer, edit_descriptors[i].new_start_offset, &edit_descriptors[i].new_start_point) ||
        !point_for_offset(manager->buffer, edit_descriptors[i].new_end_offset, &edit_descriptors[i].new_end_point)) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(edit_descriptors);
      free(cursor_mappings);
      free(sorted);
      return rejected_result(edit_count);
    }
  }

  if (changed && manager->buffer->has_undo_graph) {
    bool undo_ok = false;
    if (undo_mode == APPLY_UNDO_UPDATE_CURRENT) {
      undo_ok = buffer_update_undo(manager->buffer, op_offset);
    } else {
      undo_ok = undo_graph_commit(&manager->buffer->undo_graph, &manager->buffer->tree, changed_start) != NULL;
    }
    result.undo_node_after = manager->buffer->undo_graph.current;
    if (!undo_ok) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(edit_descriptors);
      free(cursor_mappings);
      free(sorted);
      return rejected_result(edit_count);
    }
  }

  if (changed) buffer_refresh_line_ending_mode(manager->buffer);

  piece_tree_snapshot_release(&before);

  free(sorted);

  result.applied = true;
  result.rejected = false;
  result.changed_start = changed ? changed_start : original_len;
  result.changed_old_end = changed ? changed_old_end : original_len;
  result.changed_new_end = changed_new_end;
  result.changed_old_start_line = changed_old_start_line;
  result.changed_old_end_line = changed_old_end_line;
  result.changed_new_start_line = changed_new_start_line;
  result.changed_new_end_line = changed_new_end_line;
  result.cursor_mappings = cursor_mappings;
  result.cursor_mapping_count = edit_count;
  result.edit_descriptors = edit_descriptors;
  result.edit_descriptor_count = edit_count;
  notify_edit(manager, &result, source);
  return result;
}

BatchEditResult buffer_manager_apply_edits(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count
) {
  return buffer_manager_apply_edits_from(manager, edits, edit_count, NULL);
}

BatchEditResult buffer_manager_apply_edits_from(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count,
  void *source
) {
  return buffer_manager_apply_edits_internal(manager, edits, edit_count, source, APPLY_UNDO_COMMIT, 0);
}

BatchEditResult buffer_manager_apply_edits_update_undo_from(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count,
  size_t op_offset,
  void *source
) {
  return buffer_manager_apply_edits_internal(manager, edits, edit_count, source, APPLY_UNDO_UPDATE_CURRENT, op_offset);
}
