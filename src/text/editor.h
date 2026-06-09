#ifndef ANVIL_TEXT_EDITOR_H
#define ANVIL_TEXT_EDITOR_H

#include "text/buffer_manager.h"

#include <stdbool.h>
#include <stddef.h>

#define EDITOR_SELECTION_SENTINEL ((size_t) -1)
#define EDITOR_DESIRED_COLUMN_SENTINEL ((size_t) -1)

typedef struct Cursor {
  size_t cursor;
  size_t selection;
  size_t desired_column;
} Cursor;

typedef struct Editor {
  BufferManager *buffer_manager;
  Cursor core_cursor;
  Cursor *multi_cursors;
  size_t multi_cursor_count;
  size_t multi_cursor_capacity;
} Editor;

bool editor_init(Editor *editor, BufferManager *buffer_manager);
void editor_dispose(Editor *editor);

size_t editor_cursor_count(const Editor *editor);
Cursor editor_get_cursor(const Editor *editor, size_t index);

bool editor_set_cursor(Editor *editor, size_t cursor, size_t selection);
bool editor_add_cursor(Editor *editor, size_t cursor, size_t selection);
void editor_clear_multi_cursors(Editor *editor);
void editor_sort_and_merge_cursors(Editor *editor);

bool editor_insert_buffer(Editor *editor, const char *text, size_t len);
bool editor_insert_char(Editor *editor, char ch);
bool editor_insert_newline(Editor *editor);
bool editor_backspace(Editor *editor);
bool editor_del(Editor *editor);
bool editor_select_all(Editor *editor);
bool editor_left(Editor *editor, bool update_selection);
bool editor_right(Editor *editor, bool update_selection);
bool editor_beginning_of_line(Editor *editor, bool update_selection);
bool editor_end_of_line(Editor *editor, bool update_selection);
bool editor_line_up(Editor *editor, bool update_selection);
bool editor_line_down(Editor *editor, bool update_selection);

#endif
