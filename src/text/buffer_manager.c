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

void buffer_manager_init(BufferManager *manager, Buffer *buffer) {
  if (!manager) return;
  manager->buffer = buffer;
}

BatchEditResult buffer_manager_apply_edits(
  BufferManager *manager,
  const BatchEditItem *edits,
  size_t edit_count
) {
  BatchEditResult result;
  memset(&result, 0, sizeof(result));
  result.edit_count = edit_count;

  if (!manager || !manager->buffer) return rejected_result(edit_count);
  if (edit_count == 0) {
    result.applied = true;
    result.changed_start = buffer_len(manager->buffer);
    result.changed_old_end = result.changed_start;
    result.changed_new_end = result.changed_start;
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

  PieceTreeSnapshot before = piece_tree_snapshot_acquire(&manager->buffer->tree);
  for (size_t i = edit_count; i > 0; --i) {
    BatchEditItem edit = sorted[i - 1].edit;
    size_t remove_len = edit.end_offset - edit.start_offset;
    if (remove_len > 0 && !piece_tree_remove(&manager->buffer->tree, edit.start_offset, remove_len)) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(sorted);
      return rejected_result(edit_count);
    }
    if (edit.text_len > 0 && !piece_tree_insert(&manager->buffer->tree, edit.start_offset, edit.text, edit.text_len)) {
      piece_tree_restore_snapshot(&manager->buffer->tree, &before);
      piece_tree_snapshot_release(&before);
      free(sorted);
      return rejected_result(edit_count);
    }
  }
  piece_tree_snapshot_release(&before);

  free(sorted);

  result.applied = true;
  result.rejected = false;
  result.changed_start = changed ? changed_start : original_len;
  result.changed_old_end = changed ? changed_old_end : original_len;
  result.changed_new_end = changed
    ? changed_old_end - removed_total + inserted_total
    : original_len;
  return result;
}
