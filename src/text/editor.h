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
  size_t last_insert;
  bool has_last_insert;
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
bool editor_open_line_above(Editor *editor);
bool editor_open_line_below(Editor *editor);
bool editor_backspace(Editor *editor);
bool editor_del(Editor *editor);
bool editor_backspace_word(Editor *editor);
bool editor_del_word(Editor *editor);
bool editor_delete_line(Editor *editor);
bool editor_move_line_up(Editor *editor);
bool editor_move_line_down(Editor *editor);
bool editor_join_line_below(Editor *editor);
bool editor_tab(Editor *editor);
bool editor_untab(Editor *editor);
bool editor_select_all(Editor *editor);
bool editor_select_word(Editor *editor);
bool editor_select_line(Editor *editor);
char *editor_selection_to_string(const Editor *editor, size_t *len_out);
bool editor_left(Editor *editor, bool update_selection);
bool editor_right(Editor *editor, bool update_selection);
bool editor_word_left(Editor *editor, bool update_selection);
bool editor_word_right(Editor *editor, bool update_selection);
bool editor_beginning_of_line(Editor *editor, bool update_selection);
bool editor_end_of_line(Editor *editor, bool update_selection);
bool editor_line_up(Editor *editor, bool update_selection);
bool editor_line_down(Editor *editor, bool update_selection);
bool editor_undo(Editor *editor);
bool editor_redo(Editor *editor);

#endif
