#include "text/buffer.h"
#include "text/buffer_manager.h"
#include "text/editor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond) do { \
  if (!(cond)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    return 1; \
  } \
} while (0)

typedef struct EditorFixture {
  Buffer buffer;
  BufferManager manager;
  Editor editor;
} EditorFixture;

static bool fixture_init(EditorFixture *fixture, const char *text) {
  if (!buffer_init(&fixture->buffer, text, strlen(text))) return false;
  buffer_manager_init(&fixture->manager, &fixture->buffer);
  if (!editor_init(&fixture->editor, &fixture->manager)) {
    buffer_dispose(&fixture->buffer);
    return false;
  }
  return true;
}

static void fixture_dispose(EditorFixture *fixture) {
  editor_dispose(&fixture->editor);
  buffer_dispose(&fixture->buffer);
}

static int expect_text(EditorFixture *fixture, const char *expected) {
  size_t len = 0;
  char *actual = buffer_to_string(&fixture->buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == strlen(expected));
  CHECK(memcmp(actual, expected, len) == 0);
  free(actual);
  return 0;
}

static int expect_cursor(Editor *editor, size_t index, size_t cursor, size_t selection) {
  Cursor c = editor_get_cursor(editor, index);
  CHECK(c.cursor == cursor);
  CHECK(c.selection == selection);
  return 0;
}

static int test_insert_buffer_at_cursor(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc"));
  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_insert_buffer(&f.editor, "XYZ", 3));
  CHECK(expect_text(&f, "aXYZbc") == 0);
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_insert_replaces_selection(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcdef"));
  CHECK(editor_set_cursor(&f.editor, 5, 2));
  CHECK(editor_insert_buffer(&f.editor, "X", 1));
  CHECK(expect_text(&f, "abXf") == 0);
  CHECK(expect_cursor(&f.editor, 0, 3, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_backspace_and_delete(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcdef"));
  CHECK(editor_set_cursor(&f.editor, 3, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_backspace(&f.editor));
  CHECK(expect_text(&f, "abdef") == 0);
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_del(&f.editor));
  CHECK(expect_text(&f, "abef") == 0);
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_backspace_removes_selection(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcdef"));
  CHECK(editor_set_cursor(&f.editor, 5, 2));
  CHECK(editor_backspace(&f.editor));
  CHECK(expect_text(&f, "abf") == 0);
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_multi_cursor_insert_uses_pre_edit_coordinates(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc\ndef\nghi"));
  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 5, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 9, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_cursor_count(&f.editor) == 3);
  CHECK(editor_insert_buffer(&f.editor, "X", 1));
  CHECK(expect_text(&f, "aXbc\ndXef\ngXhi") == 0);
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 1, 7, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 2, 12, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_multi_cursor_backspace(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc\ndef\nghi"));
  CHECK(editor_set_cursor(&f.editor, 2, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 6, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 10, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_backspace(&f.editor));
  CHECK(expect_text(&f, "ac\ndf\ngi") == 0);
  CHECK(expect_cursor(&f.editor, 0, 1, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 1, 4, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 2, 7, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_select_all_and_replace(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc\ndef"));
  CHECK(editor_select_all(&f.editor));
  CHECK(expect_cursor(&f.editor, 0, 7, 0) == 0);
  CHECK(editor_insert_newline(&f.editor));
  CHECK(expect_text(&f, "\n") == 0);
  CHECK(expect_cursor(&f.editor, 0, 1, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_left_right_selection_behavior(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcd"));
  CHECK(editor_set_cursor(&f.editor, 2, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_right(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 3, 2) == 0);
  CHECK(editor_left(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_left(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 1, 2) == 0);
  CHECK(editor_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_line_start_end_movement(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc\ndef\nxy"));
  CHECK(editor_set_cursor(&f.editor, 5, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_beginning_of_line(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_end_of_line(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 7, 4) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_line_down_up_preserves_desired_column(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcd\nxy\n123456"));
  CHECK(editor_set_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_line_down(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 7, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_line_down(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 12, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_line_up(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 7, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_line_movement_extends_selection(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abcd\nxy\n123456"));
  CHECK(editor_set_cursor(&f.editor, 2, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_line_down(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 7, 2) == 0);
  CHECK(editor_line_down(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 10, 2) == 0);
  CHECK(editor_line_up(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_editor_undo_redo_places_cursor_at_operation_offset(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc"));
  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_insert_buffer(&f.editor, "XYZ", 3));
  CHECK(expect_text(&f, "aXYZbc") == 0);
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);

  CHECK(editor_undo(&f.editor));
  CHECK(expect_text(&f, "abc") == 0);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);

  CHECK(editor_redo(&f.editor));
  CHECK(expect_text(&f, "aXYZbc") == 0);
  CHECK(expect_cursor(&f.editor, 0, 1, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_editor_undo_clears_multi_cursors(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "abc\ndef"));
  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 5, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_insert_buffer(&f.editor, "X", 1));
  CHECK(expect_text(&f, "aXbc\ndXef") == 0);
  CHECK(editor_cursor_count(&f.editor) == 2);

  CHECK(editor_undo(&f.editor));
  CHECK(expect_text(&f, "abc\ndef") == 0);
  CHECK(editor_cursor_count(&f.editor) == 1);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_insert_buffer_at_cursor();
  rc |= test_insert_replaces_selection();
  rc |= test_backspace_and_delete();
  rc |= test_backspace_removes_selection();
  rc |= test_multi_cursor_insert_uses_pre_edit_coordinates();
  rc |= test_multi_cursor_backspace();
  rc |= test_select_all_and_replace();
  rc |= test_left_right_selection_behavior();
  rc |= test_line_start_end_movement();
  rc |= test_line_down_up_preserves_desired_column();
  rc |= test_line_movement_extends_selection();
  rc |= test_editor_undo_redo_places_cursor_at_operation_offset();
  rc |= test_editor_undo_clears_multi_cursors();
  return rc;
}
