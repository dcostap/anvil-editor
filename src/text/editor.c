#include "text/editor.h"

#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct CursorEdit {
  BatchEditItem edit;
  size_t cursor_index;
} CursorEdit;

typedef struct LineDeleteRange {
  size_t first_line;
  size_t last_line;
} LineDeleteRange;

static Cursor make_cursor(size_t cursor, size_t selection) {
  Cursor c;
  c.cursor = cursor;
  c.selection = selection;
  c.desired_column = EDITOR_DESIRED_COLUMN_SENTINEL;
  return c;
}

static Buffer *editor_buffer(const Editor *editor) {
  if (!editor || !editor->buffer_manager) return NULL;
  return editor->buffer_manager->buffer;
}

static bool valid_locus(const Editor *editor, size_t offset) {
  Buffer *buffer = editor_buffer(editor);
  return buffer && offset <= buffer_len(buffer);
}

static bool cursor_has_selection(const Cursor *cursor) {
  return cursor->selection != EDITOR_SELECTION_SENTINEL && cursor->selection != cursor->cursor;
}

static bool cursor_has_selection_or_anchor(const Cursor *cursor) {
  return cursor->selection != EDITOR_SELECTION_SENTINEL;
}

static size_t cursor_start(const Cursor *cursor) {
  return cursor_has_selection(cursor) && cursor->selection < cursor->cursor
    ? cursor->selection
    : cursor->cursor;
}

static size_t cursor_end(const Cursor *cursor) {
  return cursor_has_selection(cursor) && cursor->selection > cursor->cursor
    ? cursor->selection
    : cursor->cursor;
}

static Cursor *active_cursors(Editor *editor, size_t *count_out) {
  if (editor->multi_cursor_count > 0) {
    *count_out = editor->multi_cursor_count;
    return editor->multi_cursors;
  }
  *count_out = 1;
  return &editor->core_cursor;
}

static const Cursor *active_cursors_const(const Editor *editor, size_t *count_out) {
  if (editor->multi_cursor_count > 0) {
    *count_out = editor->multi_cursor_count;
    return editor->multi_cursors;
  }
  *count_out = 1;
  return &editor->core_cursor;
}

static int compare_cursors(const void *a, const void *b) {
  const Cursor *ca = (const Cursor *) a;
  const Cursor *cb = (const Cursor *) b;
  size_t sa = cursor_start(ca);
  size_t sb = cursor_start(cb);
  if (sa < sb) return -1;
  if (sa > sb) return 1;
  size_t ea = cursor_end(ca);
  size_t eb = cursor_end(cb);
  if (ea < eb) return -1;
  if (ea > eb) return 1;
  if (ca->cursor < cb->cursor) return -1;
  if (ca->cursor > cb->cursor) return 1;
  return 0;
}

static int compare_line_delete_ranges(const void *a, const void *b) {
  const LineDeleteRange *ra = (const LineDeleteRange *) a;
  const LineDeleteRange *rb = (const LineDeleteRange *) b;
  if (ra->first_line < rb->first_line) return -1;
  if (ra->first_line > rb->first_line) return 1;
  if (ra->last_line < rb->last_line) return -1;
  if (ra->last_line > rb->last_line) return 1;
  return 0;
}

static int compare_cursor_mappings_by_old_range(const void *a, const void *b);
static void map_cursor_through_sorted_mappings(
  Cursor *cursor,
  const BatchCursorMapping *mappings,
  size_t mapping_count
);

static bool ensure_multi_capacity(Editor *editor, size_t needed) {
  if (needed <= editor->multi_cursor_capacity) return true;
  size_t cap = editor->multi_cursor_capacity ? editor->multi_cursor_capacity : 4;
  while (cap < needed) cap *= 2;
  Cursor *cursors = (Cursor *) realloc(editor->multi_cursors, cap * sizeof(Cursor));
  if (!cursors) return false;
  editor->multi_cursors = cursors;
  editor->multi_cursor_capacity = cap;
  return true;
}

static bool append_bytes(char **data, size_t *len, size_t *cap, const char *bytes, size_t byte_count) {
  if (!data || !len || !cap || (byte_count > 0 && !bytes)) return false;
  if (byte_count > SIZE_MAX - *len - 1) return false;
  size_t needed = *len + byte_count + 1;
  if (needed > *cap) {
    size_t new_cap = *cap ? *cap : 32;
    while (new_cap < needed) {
      if (new_cap > SIZE_MAX / 2) {
        new_cap = needed;
        break;
      }
      new_cap *= 2;
    }
    char *new_data = (char *) realloc(*data, new_cap);
    if (!new_data) return false;
    *data = new_data;
    *cap = new_cap;
  }
  if (byte_count > 0) memcpy(*data + *len, bytes, byte_count);
  *len += byte_count;
  (*data)[*len] = '\0';
  return true;
}

static void sync_core_from_multi(Editor *editor) {
  if (editor->multi_cursor_count > 0) editor->core_cursor = editor->multi_cursors[0];
}

static bool line_end_no_lf(const Buffer *buffer, size_t line, size_t *offset_out) {
  if (!buffer || !offset_out) return false;
  BufferLineRange range;
  if (!buffer_line_range_crlf(buffer, line, &range)) return false;
  *offset_out = range.end;
  return true;
}

static bool line_length_no_lf(const Buffer *buffer, size_t line, size_t *len_out) {
  if (!buffer || !len_out) return false;
  size_t start = 0;
  size_t end = 0;
  if (!buffer_line_start(buffer, line, &start)) return false;
  if (!line_end_no_lf(buffer, line, &end)) return false;
  *len_out = end >= start ? end - start : 0;
  return true;
}

static bool move_cursor_to(Editor *editor, Cursor *cursor, size_t offset, bool update_selection) {
  if (!valid_locus(editor, offset)) return false;
  size_t old = cursor->cursor;
  cursor->cursor = offset;
  if (update_selection) {
    if (cursor->selection == EDITOR_SELECTION_SENTINEL) cursor->selection = old;
  } else {
    cursor->selection = EDITOR_SELECTION_SENTINEL;
  }
  return true;
}

static void clear_desired_column(Cursor *cursor) {
  cursor->desired_column = EDITOR_DESIRED_COLUMN_SENTINEL;
}

static bool ensure_desired_column(Editor *editor, Cursor *cursor) {
  if (cursor->desired_column != EDITOR_DESIRED_COLUMN_SENTINEL) return true;
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(editor_buffer(editor), cursor->cursor, &lc)) return false;
  cursor->desired_column = lc.col;
  return true;
}

typedef enum WordSort {
  WORD_SORT_NONE,
  WORD_SORT_REGULAR,
  WORD_SORT_SEPARATOR,
  WORD_SORT_WHITESPACE,
  WORD_SORT_CR,
  WORD_SORT_NEWLINE,
} WordSort;

static bool is_separator_byte(unsigned char ch) {
  return strchr("`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?", (int) ch) != NULL;
}

static WordSort categorize_byte(unsigned char ch) {
  if (ch == '\n') return WORD_SORT_NEWLINE;
  if (ch == '\r') return WORD_SORT_CR;
  if (isspace((int) ch)) return WORD_SORT_WHITESPACE;
  if (isalnum((int) ch) || ch == '_' || ch >= 0x80) return WORD_SORT_REGULAR;
  if (is_separator_byte(ch)) return WORD_SORT_SEPARATOR;
  return WORD_SORT_NONE;
}

static size_t extend_by_word_bytes(const char *bytes, size_t len, size_t offset) {
  if (!bytes || offset >= len) return len;
  int state = 0;
  size_t pos = offset;
  while (pos < len) {
    WordSort sort = categorize_byte((unsigned char) bytes[pos]);
    bool boundary = false;
    if (sort == WORD_SORT_REGULAR) {
      boundary = state == 2;
      state = 1;
    } else if (sort == WORD_SORT_SEPARATOR) {
      boundary = state == 1;
      state = 2;
    } else if (sort == WORD_SORT_WHITESPACE) {
      boundary = state != 0 && state != 3;
      state = 3;
    } else if (sort == WORD_SORT_CR) {
      state = 4;
    } else if (sort == WORD_SORT_NEWLINE) {
      boundary = state != 0;
      state = 5;
    }
    if (boundary) return pos;
    ++pos;
  }
  return len;
}

static size_t retract_by_word_bytes(const char *bytes, size_t len, size_t offset) {
  if (!bytes || offset == 0) return 0;
  if (offset > len) offset = len;
  int state = 0;
  size_t pos = offset;
  while (pos > 0) {
    size_t cur = pos - 1;
    WordSort sort = categorize_byte((unsigned char) bytes[cur]);
    bool boundary = false;
    if (sort == WORD_SORT_REGULAR) {
      boundary = state == 2;
      state = 1;
    } else if (sort == WORD_SORT_SEPARATOR) {
      boundary = state == 1;
      state = 2;
    } else if (sort == WORD_SORT_WHITESPACE) {
      boundary = state != 0 && state != 3;
      state = 3;
    } else if (sort == WORD_SORT_CR) {
      state = 4;
    } else if (sort == WORD_SORT_NEWLINE) {
      boundary = state != 0;
      state = 5;
    }
    if (boundary) return pos;
    pos = cur;
  }
  return 0;
}

static int compare_cursor_mappings_by_old_range(const void *a, const void *b) {
  const BatchCursorMapping *ma = (const BatchCursorMapping *) a;
  const BatchCursorMapping *mb = (const BatchCursorMapping *) b;
  if (ma->old_start_offset < mb->old_start_offset) return -1;
  if (ma->old_start_offset > mb->old_start_offset) return 1;
  if (ma->old_end_offset < mb->old_end_offset) return -1;
  if (ma->old_end_offset > mb->old_end_offset) return 1;
  return 0;
}

static size_t add_signed_delta(size_t value, ptrdiff_t delta) {
  if (delta < 0) {
    size_t abs_delta = (size_t) -delta;
    return value > abs_delta ? value - abs_delta : 0;
  }
  if ((size_t) delta > SIZE_MAX - value) return SIZE_MAX;
  return value + (size_t) delta;
}

static size_t map_locus_through_sorted_mappings(
  size_t locus,
  const BatchCursorMapping *mappings,
  size_t mapping_count
) {
  ptrdiff_t delta = 0;
  for (size_t i = 0; i < mapping_count; ++i) {
    size_t start = mappings[i].old_start_offset;
    size_t end = mappings[i].old_end_offset;
    size_t inserted_len = mappings[i].new_end_offset - mappings[i].new_start_offset;
    if (locus <= start) return add_signed_delta(locus, delta);
    if (locus <= end) return add_signed_delta(start, delta);
    delta += (ptrdiff_t) inserted_len - (ptrdiff_t) (end - start);
  }
  return add_signed_delta(locus, delta);
}

static void map_cursor_through_sorted_mappings(
  Cursor *cursor,
  const BatchCursorMapping *mappings,
  size_t mapping_count
) {
  cursor->cursor = map_locus_through_sorted_mappings(cursor->cursor, mappings, mapping_count);
  if (cursor->selection != EDITOR_SELECTION_SENTINEL) {
    cursor->selection = map_locus_through_sorted_mappings(cursor->selection, mappings, mapping_count);
  }
  clear_desired_column(cursor);
}

static void editor_finish_external_buffer_update(Editor *editor) {
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
}

static void editor_on_buffer_edit(void *user, const BatchEditResult *result, void *source) {
  Editor *editor = (Editor *) user;
  if (!editor || editor == source || !result || !result->applied || result->cursor_mapping_count == 0) return;

  BatchCursorMapping *mappings = (BatchCursorMapping *) malloc(sizeof(BatchCursorMapping) * result->cursor_mapping_count);
  if (!mappings) return;
  memcpy(mappings, result->cursor_mappings, sizeof(BatchCursorMapping) * result->cursor_mapping_count);
  qsort(mappings, result->cursor_mapping_count, sizeof(BatchCursorMapping), compare_cursor_mappings_by_old_range);

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) map_cursor_through_sorted_mappings(&cursors[i], mappings, result->cursor_mapping_count);

  free(mappings);
  editor_finish_external_buffer_update(editor);
}

static void editor_on_buffer_snap(void *user, const BufferSnapResult *result, void *source) {
  Editor *editor = (Editor *) user;
  if (!editor || editor == source || !result || !result->applied) return;
  if (result->changed_start == result->changed_old_end && result->changed_start == result->changed_new_end) return;

  BatchCursorMapping mapping;
  memset(&mapping, 0, sizeof(mapping));
  mapping.old_start_offset = result->changed_start;
  mapping.old_end_offset = result->changed_old_end;
  mapping.new_start_offset = result->changed_start;
  mapping.new_end_offset = result->changed_new_end;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) map_cursor_through_sorted_mappings(&cursors[i], &mapping, 1);

  editor_finish_external_buffer_update(editor);
}

bool editor_init(Editor *editor, BufferManager *buffer_manager) {
  if (!editor || !buffer_manager || !buffer_manager->buffer) return false;
  memset(editor, 0, sizeof(*editor));
  editor->buffer_manager = buffer_manager;
  editor->core_cursor = make_cursor(0, EDITOR_SELECTION_SENTINEL);
  if (!buffer_manager_register_listener(buffer_manager, editor, editor_on_buffer_edit, editor_on_buffer_snap)) {
    memset(editor, 0, sizeof(*editor));
    return false;
  }
  return true;
}

void editor_dispose(Editor *editor) {
  if (!editor) return;
  if (editor->buffer_manager) buffer_manager_unregister_listener(editor->buffer_manager, editor);
  free(editor->multi_cursors);
  memset(editor, 0, sizeof(*editor));
}

size_t editor_cursor_count(const Editor *editor) {
  if (!editor) return 0;
  return editor->multi_cursor_count > 0 ? editor->multi_cursor_count : 1;
}

Cursor editor_get_cursor(const Editor *editor, size_t index) {
  if (!editor) return make_cursor(0, EDITOR_SELECTION_SENTINEL);
  if (editor->multi_cursor_count > 0) {
    if (index >= editor->multi_cursor_count) return make_cursor(0, EDITOR_SELECTION_SENTINEL);
    return editor->multi_cursors[index];
  }
  return index == 0 ? editor->core_cursor : make_cursor(0, EDITOR_SELECTION_SENTINEL);
}

bool editor_set_cursor(Editor *editor, size_t cursor, size_t selection) {
  if (!editor || !valid_locus(editor, cursor)) return false;
  if (selection != EDITOR_SELECTION_SENTINEL && !valid_locus(editor, selection)) return false;
  editor_clear_multi_cursors(editor);
  editor->core_cursor = make_cursor(cursor, selection);
  return true;
}

bool editor_add_cursor(Editor *editor, size_t cursor, size_t selection) {
  if (!editor || !valid_locus(editor, cursor)) return false;
  if (selection != EDITOR_SELECTION_SENTINEL && !valid_locus(editor, selection)) return false;
  if (editor->multi_cursor_count == 0) {
    if (!ensure_multi_capacity(editor, 2)) return false;
    editor->multi_cursors[editor->multi_cursor_count++] = editor->core_cursor;
  } else if (!ensure_multi_capacity(editor, editor->multi_cursor_count + 1)) {
    return false;
  }
  editor->multi_cursors[editor->multi_cursor_count++] = make_cursor(cursor, selection);
  editor_sort_and_merge_cursors(editor);
  return true;
}

void editor_clear_multi_cursors(Editor *editor) {
  if (!editor) return;
  editor->multi_cursor_count = 0;
}

void editor_sort_and_merge_cursors(Editor *editor) {
  if (!editor || editor->multi_cursor_count == 0) return;
  qsort(editor->multi_cursors, editor->multi_cursor_count, sizeof(Cursor), compare_cursors);

  size_t out = 0;
  for (size_t i = 0; i < editor->multi_cursor_count; ++i) {
    Cursor cur = editor->multi_cursors[i];
    if (out == 0) {
      editor->multi_cursors[out++] = cur;
      continue;
    }

    Cursor *prev = &editor->multi_cursors[out - 1];
    size_t prev_start = cursor_start(prev);
    size_t prev_end = cursor_end(prev);
    size_t cur_start = cursor_start(&cur);
    size_t cur_end = cursor_end(&cur);

    if (!cursor_has_selection(prev) && !cursor_has_selection(&cur) && prev->cursor == cur.cursor) {
      continue;
    }

    if (cursor_has_selection(prev) && cursor_has_selection(&cur) && cur_start <= prev_end) {
      size_t merged_start = prev_start < cur_start ? prev_start : cur_start;
      size_t merged_end = prev_end > cur_end ? prev_end : cur_end;
      prev->selection = merged_start;
      prev->cursor = merged_end;
      prev->desired_column = EDITOR_DESIRED_COLUMN_SENTINEL;
      continue;
    }

    editor->multi_cursors[out++] = cur;
  }

  editor->multi_cursor_count = out;
  sync_core_from_multi(editor);
}

static bool apply_cursor_edits(Editor *editor, CursorEdit *cursor_edits, size_t count) {
  if (count == 0) return true;
  BatchEditItem *items = (BatchEditItem *) malloc(sizeof(BatchEditItem) * count);
  if (!items) return false;
  for (size_t i = 0; i < count; ++i) items[i] = cursor_edits[i].edit;

  BatchEditResult result = buffer_manager_apply_edits_from(editor->buffer_manager, items, count, editor);
  free(items);
  if (!result.applied) {
    batch_edit_result_dispose(&result);
    return false;
  }

  for (size_t i = 0; i < result.cursor_mapping_count; ++i) {
    BatchCursorMapping mapping = result.cursor_mappings[i];
    size_t cursor_index = (size_t) mapping.cursor_index;
    if (editor->multi_cursor_count > 0) {
      if (cursor_index >= editor->multi_cursor_count) {
        batch_edit_result_dispose(&result);
        return false;
      }
      editor->multi_cursors[cursor_index] = make_cursor(mapping.new_cursor_offset, EDITOR_SELECTION_SENTINEL);
    } else {
      editor->core_cursor = make_cursor(mapping.new_cursor_offset, EDITOR_SELECTION_SENTINEL);
    }
  }

  batch_edit_result_dispose(&result);
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

bool editor_insert_buffer(Editor *editor, const char *text, size_t len) {
  if (!editor || (len > 0 && !text)) return false;
  editor_sort_and_merge_cursors(editor);

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  CursorEdit *edits = (CursorEdit *) malloc(sizeof(CursorEdit) * count);
  if (!edits) return false;

  for (size_t i = 0; i < count; ++i) {
    edits[i].edit.start_offset = cursor_start(&cursors[i]);
    edits[i].edit.end_offset = cursor_end(&cursors[i]);
    edits[i].edit.text = text;
    edits[i].edit.text_len = len;
    edits[i].edit.cursor_index = (unsigned int) i;
    edits[i].cursor_index = i;
  }

  bool ok = apply_cursor_edits(editor, edits, count);
  free(edits);
  return ok;
}

bool editor_insert_char(Editor *editor, char ch) {
  return editor_insert_buffer(editor, &ch, 1);
}

bool editor_insert_newline(Editor *editor) {
  return editor_insert_buffer(editor, "\n", 1);
}

bool editor_backspace(Editor *editor) {
  if (!editor) return false;
  editor_sort_and_merge_cursors(editor);
  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  CursorEdit *edits = (CursorEdit *) calloc(count, sizeof(CursorEdit));
  if (!edits) return false;

  size_t edit_count = 0;
  for (size_t i = 0; i < count; ++i) {
    size_t start = cursor_start(&cursors[i]);
    size_t end = cursor_end(&cursors[i]);
    if (start == end) {
      if (start == 0) continue;
      --start;
    }
    edits[edit_count].edit.start_offset = start;
    edits[edit_count].edit.end_offset = end;
    edits[edit_count].edit.text = NULL;
    edits[edit_count].edit.text_len = 0;
    edits[edit_count].edit.cursor_index = (unsigned int) i;
    edits[edit_count].cursor_index = i;
    ++edit_count;
  }

  bool ok = edit_count == 0 ? true : apply_cursor_edits(editor, edits, edit_count);
  free(edits);
  return ok;
}

bool editor_del(Editor *editor) {
  if (!editor) return false;
  editor_sort_and_merge_cursors(editor);
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  size_t buffer_length = buffer_len(buffer);

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  CursorEdit *edits = (CursorEdit *) calloc(count, sizeof(CursorEdit));
  if (!edits) return false;

  size_t edit_count = 0;
  for (size_t i = 0; i < count; ++i) {
    size_t start = cursor_start(&cursors[i]);
    size_t end = cursor_end(&cursors[i]);
    if (start == end) {
      if (end >= buffer_length) continue;
      ++end;
    }
    edits[edit_count].edit.start_offset = start;
    edits[edit_count].edit.end_offset = end;
    edits[edit_count].edit.text = NULL;
    edits[edit_count].edit.text_len = 0;
    edits[edit_count].edit.cursor_index = (unsigned int) i;
    edits[edit_count].cursor_index = i;
    ++edit_count;
  }

  bool ok = edit_count == 0 ? true : apply_cursor_edits(editor, edits, edit_count);
  free(edits);
  return ok;
}

static bool line_delete_range_to_offsets(
  const Buffer *buffer,
  LineDeleteRange line_range,
  size_t *start_out,
  size_t *end_out
) {
  if (!buffer || !start_out || !end_out) return false;
  size_t line_count = buffer_line_count(buffer);
  if (line_count == 0 || line_range.first_line >= line_count) return false;
  if (line_range.last_line >= line_count) line_range.last_line = line_count - 1;
  if (line_range.last_line < line_range.first_line) return false;

  size_t start = 0;
  size_t end = 0;
  if (!buffer_line_start(buffer, line_range.first_line, &start)) return false;
  if (line_range.last_line + 1 < line_count) {
    if (!buffer_line_start(buffer, line_range.last_line + 1, &end)) return false;
  } else {
    end = buffer_len(buffer);
    if (line_range.first_line > 0) {
      char ch = 0;
      if (start > 0 && piece_tree_byte_at(&buffer->tree, start - 1, &ch) && ch == '\n') {
        --start;
        if (start > 0 && piece_tree_byte_at(&buffer->tree, start - 1, &ch) && ch == '\r') --start;
      }
    }
  }

  *start_out = start;
  *end_out = end;
  return true;
}

static bool cursor_line_range(Editor *editor, const Cursor *cursor, LineDeleteRange *out) {
  if (!editor || !cursor || !out) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t start = cursor_start(cursor);
  size_t end = cursor_end(cursor);
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(buffer, start, &lc)) return false;
  out->first_line = lc.line;
  if (!buffer_offset_to_line_col(buffer, end, &lc)) return false;
  out->last_line = lc.line;
  return true;
}

static bool move_cursor_to_current_line_start(Editor *editor, Cursor *cursor) {
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  size_t len = buffer_len(buffer);
  if (cursor->cursor > len) cursor->cursor = len;
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(buffer, cursor->cursor, &lc)) return false;
  size_t start = 0;
  if (!buffer_line_start(buffer, lc.line, &start)) return false;
  cursor->cursor = start;
  cursor->selection = EDITOR_SELECTION_SENTINEL;
  clear_desired_column(cursor);
  return true;
}

bool editor_delete_line(Editor *editor) {
  if (!editor) return false;
  editor_sort_and_merge_cursors(editor);
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  LineDeleteRange *ranges = (LineDeleteRange *) calloc(count, sizeof(LineDeleteRange));
  if (!ranges) return false;

  size_t range_count = 0;
  for (size_t i = 0; i < count; ++i) {
    if (!cursor_line_range(editor, &cursors[i], &ranges[range_count])) {
      free(ranges);
      return false;
    }
    ++range_count;
  }

  qsort(ranges, range_count, sizeof(LineDeleteRange), compare_line_delete_ranges);
  size_t merged_count = 0;
  for (size_t i = 0; i < range_count; ++i) {
    if (merged_count == 0 || ranges[i].first_line > ranges[merged_count - 1].last_line + 1) {
      ranges[merged_count++] = ranges[i];
    } else if (ranges[i].last_line > ranges[merged_count - 1].last_line) {
      ranges[merged_count - 1].last_line = ranges[i].last_line;
    }
  }

  BatchEditItem *items = (BatchEditItem *) calloc(merged_count, sizeof(BatchEditItem));
  if (!items) {
    free(ranges);
    return false;
  }

  for (size_t i = 0; i < merged_count; ++i) {
    size_t start = 0;
    size_t end = 0;
    if (!line_delete_range_to_offsets(buffer, ranges[i], &start, &end)) {
      free(items);
      free(ranges);
      return false;
    }
    items[i].start_offset = start;
    items[i].end_offset = end;
    items[i].text = NULL;
    items[i].text_len = 0;
    items[i].cursor_index = (unsigned int) i;
  }

  BatchEditResult result = buffer_manager_apply_edits_from(editor->buffer_manager, items, merged_count, editor);
  free(items);
  free(ranges);
  if (!result.applied) {
    batch_edit_result_dispose(&result);
    return false;
  }

  BatchCursorMapping *mappings = NULL;
  if (result.cursor_mapping_count > 0) {
    mappings = (BatchCursorMapping *) malloc(sizeof(BatchCursorMapping) * result.cursor_mapping_count);
    if (!mappings) {
      batch_edit_result_dispose(&result);
      return false;
    }
    memcpy(mappings, result.cursor_mappings, sizeof(BatchCursorMapping) * result.cursor_mapping_count);
    qsort(mappings, result.cursor_mapping_count, sizeof(BatchCursorMapping), compare_cursor_mappings_by_old_range);
  }

  cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    if (mappings) map_cursor_through_sorted_mappings(&cursors[i], mappings, result.cursor_mapping_count);
    if (!move_cursor_to_current_line_start(editor, &cursors[i])) {
      free(mappings);
      batch_edit_result_dispose(&result);
      return false;
    }
  }

  free(mappings);
  batch_edit_result_dispose(&result);
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

static bool editor_word_delete(Editor *editor, int direction) {
  if (!editor) return false;
  editor_sort_and_merge_cursors(editor);
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t len = 0;
  char *bytes = buffer_to_string(buffer, &len);
  if (!bytes) return false;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  CursorEdit *edits = (CursorEdit *) calloc(count, sizeof(CursorEdit));
  if (!edits) {
    free(bytes);
    return false;
  }

  size_t edit_count = 0;
  for (size_t i = 0; i < count; ++i) {
    size_t start = cursor_start(&cursors[i]);
    size_t end = cursor_end(&cursors[i]);
    if (start == end) {
      if (direction < 0) {
        if (start == 0) continue;
        start = retract_by_word_bytes(bytes, len, start);
      } else {
        if (end >= len) continue;
        end = extend_by_word_bytes(bytes, len, end);
      }
    }
    if (start == end) continue;
    edits[edit_count].edit.start_offset = start;
    edits[edit_count].edit.end_offset = end;
    edits[edit_count].edit.text = NULL;
    edits[edit_count].edit.text_len = 0;
    edits[edit_count].edit.cursor_index = (unsigned int) i;
    edits[edit_count].cursor_index = i;
    ++edit_count;
  }

  free(bytes);
  bool ok = edit_count == 0 ? true : apply_cursor_edits(editor, edits, edit_count);
  free(edits);
  return ok;
}

bool editor_backspace_word(Editor *editor) {
  return editor_word_delete(editor, -1);
}

bool editor_del_word(Editor *editor) {
  return editor_word_delete(editor, 1);
}

bool editor_select_all(Editor *editor) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  editor_clear_multi_cursors(editor);
  editor->core_cursor = make_cursor(buffer_len(buffer), 0);
  return true;
}

bool editor_select_word(Editor *editor) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  size_t len = 0;
  char *bytes = buffer_to_string(buffer, &len);
  if (!bytes) return false;

  editor_clear_multi_cursors(editor);
  size_t start = editor->core_cursor.cursor;
  if (start > len) start = len;
  if (start != 0) start = retract_by_word_bytes(bytes, len, start);
  size_t end = extend_by_word_bytes(bytes, len, start);
  free(bytes);

  editor->core_cursor = make_cursor(end, start);
  return true;
}

bool editor_select_line(Editor *editor) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  BufferLineCol lc;
  if (!buffer_offset_to_line_col(buffer, editor->core_cursor.cursor, &lc)) return false;
  BufferLineRange range;
  if (!buffer_line_range_crlf(buffer, lc.line, &range)) return false;

  editor_clear_multi_cursors(editor);
  editor->core_cursor = make_cursor(range.end, range.start);
  return true;
}

char *editor_selection_to_string(const Editor *editor, size_t *len_out) {
  if (!editor) return NULL;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return NULL;

  char *out = NULL;
  size_t len = 0;
  size_t cap = 0;
  if (!append_bytes(&out, &len, &cap, "", 0)) return NULL;

  size_t count = 0;
  const Cursor *cursors = active_cursors_const(editor, &count);
  bool appended_selection = false;
  for (size_t i = 0; i < count; ++i) {
    if (!cursor_has_selection_or_anchor(&cursors[i])) continue;
    size_t start = cursor_start(&cursors[i]);
    size_t end = cursor_end(&cursors[i]);
    size_t range_len = 0;
    char *range = buffer_range_to_string(buffer, start, end, &range_len);
    if (!range) {
      free(out);
      return NULL;
    }
    if (appended_selection && !append_bytes(&out, &len, &cap, "\n", 1)) {
      free(range);
      free(out);
      return NULL;
    }
    if (!append_bytes(&out, &len, &cap, range, range_len)) {
      free(range);
      free(out);
      return NULL;
    }
    appended_selection = true;
    free(range);
  }

  if (len_out) *len_out = len;
  return out;
}

bool editor_left(Editor *editor, bool update_selection) {
  if (!editor) return false;
  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];
    if (!update_selection && cursor_has_selection(cursor)) {
      cursor->cursor = cursor_start(cursor);
      cursor->selection = EDITOR_SELECTION_SENTINEL;
      clear_desired_column(cursor);
      continue;
    }
    size_t old = cursor->cursor;
    if (old > 0) --cursor->cursor;
    if (update_selection) {
      if (cursor->selection == EDITOR_SELECTION_SENTINEL) cursor->selection = old;
    } else {
      cursor->selection = EDITOR_SELECTION_SENTINEL;
    }
    clear_desired_column(cursor);
  }
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

bool editor_right(Editor *editor, bool update_selection) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  size_t len = buffer_len(buffer);
  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];
    if (!update_selection && cursor_has_selection(cursor)) {
      cursor->cursor = cursor_end(cursor);
      cursor->selection = EDITOR_SELECTION_SENTINEL;
      clear_desired_column(cursor);
      continue;
    }
    size_t old = cursor->cursor;
    if (old < len) ++cursor->cursor;
    if (update_selection) {
      if (cursor->selection == EDITOR_SELECTION_SENTINEL) cursor->selection = old;
    } else {
      cursor->selection = EDITOR_SELECTION_SENTINEL;
    }
    clear_desired_column(cursor);
  }
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

static bool editor_word_move(Editor *editor, bool update_selection, int direction) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  size_t len = 0;
  char *bytes = buffer_to_string(buffer, &len);
  if (!bytes) return false;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];
    if (!update_selection && cursor_has_selection(cursor)) {
      cursor->cursor = direction < 0 ? cursor_start(cursor) : cursor_end(cursor);
      cursor->selection = EDITOR_SELECTION_SENTINEL;
      clear_desired_column(cursor);
      continue;
    }

    size_t target = direction < 0
      ? retract_by_word_bytes(bytes, len, cursor->cursor)
      : extend_by_word_bytes(bytes, len, cursor->cursor);
    if (!move_cursor_to(editor, cursor, target, update_selection)) {
      free(bytes);
      return false;
    }
    clear_desired_column(cursor);
  }

  free(bytes);
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

bool editor_word_left(Editor *editor, bool update_selection) {
  return editor_word_move(editor, update_selection, -1);
}

bool editor_word_right(Editor *editor, bool update_selection) {
  return editor_word_move(editor, update_selection, 1);
}

bool editor_beginning_of_line(Editor *editor, bool update_selection) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];
    BufferLineCol lc;
    size_t target = 0;
    if (!buffer_offset_to_line_col(buffer, cursor->cursor, &lc)) return false;
    if (!buffer_line_start(buffer, lc.line, &target)) return false;
    if (!move_cursor_to(editor, cursor, target, update_selection)) return false;
    clear_desired_column(cursor);
  }

  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

bool editor_end_of_line(Editor *editor, bool update_selection) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];
    BufferLineCol lc;
    size_t target = 0;
    if (!buffer_offset_to_line_col(buffer, cursor->cursor, &lc)) return false;
    if (!line_end_no_lf(buffer, lc.line, &target)) return false;
    if (!move_cursor_to(editor, cursor, target, update_selection)) return false;
    clear_desired_column(cursor);
  }

  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

static bool editor_line_move(Editor *editor, bool update_selection, int direction) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  size_t line_count = buffer_line_count(buffer);
  size_t count = 0;
  Cursor *cursors = active_cursors(editor, &count);
  for (size_t i = 0; i < count; ++i) {
    Cursor *cursor = &cursors[i];

    if (!update_selection && cursor_has_selection(cursor)) {
      cursor->cursor = direction > 0 ? cursor_end(cursor) : cursor_start(cursor);
      cursor->selection = EDITOR_SELECTION_SENTINEL;
    }

    if (!ensure_desired_column(editor, cursor)) return false;

    BufferLineCol lc;
    if (!buffer_offset_to_line_col(buffer, cursor->cursor, &lc)) return false;
    size_t target_line = lc.line;
    if (direction > 0) {
      if (target_line + 1 < line_count) ++target_line;
    } else if (target_line > 0) {
      --target_line;
    }

    size_t target_line_len = 0;
    size_t target_line_start = 0;
    if (!line_length_no_lf(buffer, target_line, &target_line_len)) return false;
    if (!buffer_line_start(buffer, target_line, &target_line_start)) return false;
    size_t target_col = cursor->desired_column < target_line_len
      ? cursor->desired_column
      : target_line_len;
    if (!move_cursor_to(editor, cursor, target_line_start + target_col, update_selection)) return false;
  }

  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}

bool editor_line_up(Editor *editor, bool update_selection) {
  return editor_line_move(editor, update_selection, -1);
}

bool editor_line_down(Editor *editor, bool update_selection) {
  return editor_line_move(editor, update_selection, 1);
}

static bool editor_restore_undo_redo(Editor *editor, bool redo) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;

  editor_clear_multi_cursors(editor);
  size_t op_offset = 0;
  bool ok = redo
    ? buffer_manager_redo_from(editor->buffer_manager, &op_offset, editor)
    : buffer_manager_undo_from(editor->buffer_manager, &op_offset, editor);
  if (!ok) return false;

  size_t len = buffer_len(buffer);
  if (op_offset > len) op_offset = len;
  editor->core_cursor = make_cursor(op_offset, EDITOR_SELECTION_SENTINEL);
  return true;
}

bool editor_undo(Editor *editor) {
  return editor_restore_undo_redo(editor, false);
}

bool editor_redo(Editor *editor) {
  return editor_restore_undo_redo(editor, true);
}
