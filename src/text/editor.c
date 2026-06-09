#include "text/editor.h"

#include <stdlib.h>
#include <string.h>

typedef struct CursorEdit {
  BatchEditItem edit;
  size_t cursor_index;
} CursorEdit;

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

static void sync_core_from_multi(Editor *editor) {
  if (editor->multi_cursor_count > 0) editor->core_cursor = editor->multi_cursors[0];
}

bool editor_init(Editor *editor, BufferManager *buffer_manager) {
  if (!editor || !buffer_manager || !buffer_manager->buffer) return false;
  memset(editor, 0, sizeof(*editor));
  editor->buffer_manager = buffer_manager;
  editor->core_cursor = make_cursor(0, EDITOR_SELECTION_SENTINEL);
  return true;
}

void editor_dispose(Editor *editor) {
  if (!editor) return;
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

  BatchEditResult result = buffer_manager_apply_edits(editor->buffer_manager, items, count);
  free(items);
  if (!result.applied) return false;

  for (size_t i = 0; i < count; ++i) {
    ptrdiff_t delta = 0;
    for (size_t j = 0; j < count; ++j) {
      if (cursor_edits[j].edit.start_offset < cursor_edits[i].edit.start_offset) {
        size_t removed = cursor_edits[j].edit.end_offset - cursor_edits[j].edit.start_offset;
        size_t inserted = cursor_edits[j].edit.text_len;
        delta += (ptrdiff_t) inserted - (ptrdiff_t) removed;
      }
    }
    size_t new_cursor = (size_t) ((ptrdiff_t) cursor_edits[i].edit.start_offset + delta)
      + cursor_edits[i].edit.text_len;
    size_t cursor_index = cursor_edits[i].cursor_index;
    if (editor->multi_cursor_count > 0) {
      editor->multi_cursors[cursor_index] = make_cursor(new_cursor, EDITOR_SELECTION_SENTINEL);
    } else {
      editor->core_cursor = make_cursor(new_cursor, EDITOR_SELECTION_SENTINEL);
    }
  }

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

bool editor_select_all(Editor *editor) {
  if (!editor) return false;
  Buffer *buffer = editor_buffer(editor);
  if (!buffer) return false;
  editor_clear_multi_cursors(editor);
  editor->core_cursor = make_cursor(buffer_len(buffer), 0);
  return true;
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
      continue;
    }
    size_t old = cursor->cursor;
    if (old > 0) --cursor->cursor;
    if (update_selection) {
      if (cursor->selection == EDITOR_SELECTION_SENTINEL) cursor->selection = old;
    } else {
      cursor->selection = EDITOR_SELECTION_SENTINEL;
    }
    cursor->desired_column = EDITOR_DESIRED_COLUMN_SENTINEL;
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
      continue;
    }
    size_t old = cursor->cursor;
    if (old < len) ++cursor->cursor;
    if (update_selection) {
      if (cursor->selection == EDITOR_SELECTION_SENTINEL) cursor->selection = old;
    } else {
      cursor->selection = EDITOR_SELECTION_SENTINEL;
    }
    cursor->desired_column = EDITOR_DESIRED_COLUMN_SENTINEL;
  }
  editor_sort_and_merge_cursors(editor);
  sync_core_from_multi(editor);
  return true;
}
