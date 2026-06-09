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
  buffer_manager_dispose(&fixture->manager);
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

static int test_insert_newline_uses_buffer_line_ending_mode(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "ab\r\ncd"));
  CHECK(editor_set_cursor(&f.editor, 2, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_insert_newline(&f.editor));
  CHECK(expect_text(&f, "ab\r\n\r\ncd") == 0);
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_open_line_above_preserves_indent(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "  alpha\nbeta"));
  CHECK(editor_set_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_open_line_above(&f.editor));
  CHECK(expect_text(&f, "  \n  alpha\nbeta") == 0);
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_open_line_below_preserves_indent_before_next_line(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "  alpha\nbeta"));
  CHECK(editor_set_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_open_line_below(&f.editor));
  CHECK(expect_text(&f, "  alpha\n  \nbeta") == 0);
  CHECK(expect_cursor(&f.editor, 0, 10, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_open_line_below_last_line_uses_crlf_and_clears_multi_cursors(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "  alpha\r\n\tbeta"));
  CHECK(editor_set_cursor(&f.editor, 10, 9));
  CHECK(editor_add_cursor(&f.editor, 14, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_cursor_count(&f.editor) == 2);
  CHECK(editor_open_line_below(&f.editor));
  CHECK(expect_text(&f, "  alpha\r\n\tbeta\r\n\t") == 0);
  CHECK(editor_cursor_count(&f.editor) == 1);
  CHECK(expect_cursor(&f.editor, 0, 17, EDITOR_SELECTION_SENTINEL) == 0);
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

static int test_delete_line(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa\nbb\ncc"));
  CHECK(editor_set_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_delete_line(&f.editor));
  CHECK(expect_text(&f, "aa\ncc") == 0);
  CHECK(expect_cursor(&f.editor, 0, 3, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_delete_final_crlf_line_removes_previous_line_ending(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa\r\nbb"));
  CHECK(editor_set_cursor(&f.editor, 5, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_delete_line(&f.editor));
  CHECK(expect_text(&f, "aa") == 0);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_delete_line_removes_selected_line_span(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa\nbb\ncc\ndd"));
  CHECK(editor_set_cursor(&f.editor, 1, 7));
  CHECK(editor_delete_line(&f.editor));
  CHECK(expect_text(&f, "dd") == 0);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_multi_cursor_delete_line_merges_overlapping_line_ranges(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa\nbb\ncc\ndd"));
  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 10, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_delete_line(&f.editor));
  CHECK(expect_text(&f, "cc") == 0);
  CHECK(editor_cursor_count(&f.editor) == 1);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
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

static int test_select_word(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "foo bar,baz"));
  CHECK(editor_set_cursor(&f.editor, 6, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_select_word(&f.editor));
  CHECK(expect_cursor(&f.editor, 0, 7, 4) == 0);

  CHECK(editor_set_cursor(&f.editor, 9, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_select_word(&f.editor));
  CHECK(expect_cursor(&f.editor, 0, 11, 8) == 0);

  CHECK(editor_set_cursor(&f.editor, 8, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 0, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_cursor_count(&f.editor) == 2);
  CHECK(editor_select_word(&f.editor));
  CHECK(editor_cursor_count(&f.editor) == 1);
  CHECK(expect_cursor(&f.editor, 0, 3, 0) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_select_line(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "ab\r\ncd\nef"));
  CHECK(editor_set_cursor(&f.editor, 4, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_select_line(&f.editor));
  CHECK(expect_cursor(&f.editor, 0, 6, 4) == 0);

  CHECK(editor_set_cursor(&f.editor, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 7, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_cursor_count(&f.editor) == 2);
  CHECK(editor_select_line(&f.editor));
  CHECK(editor_cursor_count(&f.editor) == 1);
  CHECK(expect_cursor(&f.editor, 0, 2, 0) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_selection_to_string(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "alpha beta gamma"));
  CHECK(editor_set_cursor(&f.editor, 10, 6));
  size_t len = 0;
  char *selection = editor_selection_to_string(&f.editor, &len);
  CHECK(selection != NULL);
  CHECK(len == 4);
  CHECK(memcmp(selection, "beta", 4) == 0);
  free(selection);

  CHECK(editor_set_cursor(&f.editor, 5, 0));
  CHECK(editor_add_cursor(&f.editor, 16, 11));
  selection = editor_selection_to_string(&f.editor, &len);
  CHECK(selection != NULL);
  CHECK(len == 11);
  CHECK(memcmp(selection, "alpha\ngamma", 11) == 0);
  free(selection);
  fixture_dispose(&f);
  return 0;
}

static int test_selection_to_string_uses_crlf_between_multi_selections(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "alpha\r\nbeta\r\ngamma"));
  CHECK(editor_set_cursor(&f.editor, 5, 0));
  CHECK(editor_add_cursor(&f.editor, 18, 13));
  size_t len = 0;
  char *selection = editor_selection_to_string(&f.editor, &len);
  CHECK(selection != NULL);
  CHECK(len == 12);
  CHECK(memcmp(selection, "alpha\r\ngamma", 12) == 0);
  free(selection);
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

static int test_end_of_line_stops_before_crlf(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "ab\r\ncd"));
  CHECK(editor_set_cursor(&f.editor, 0, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_end_of_line(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_word_left_right_movement(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "foo bar,baz\nqux"));
  CHECK(editor_set_cursor(&f.editor, 0, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 3, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 7, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 8, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 11, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_word_left(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 8, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_word_left(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 7, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_word_delete_commands(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "foo bar,baz"));
  CHECK(editor_set_cursor(&f.editor, 7, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_backspace_word(&f.editor));
  CHECK(expect_text(&f, "foo ,baz") == 0);
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_del_word(&f.editor));
  CHECK(expect_text(&f, "foo baz") == 0);
  CHECK(expect_cursor(&f.editor, 0, 4, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_word_delete_removes_selection(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "alpha beta gamma"));
  CHECK(editor_set_cursor(&f.editor, 11, 6));
  CHECK(editor_backspace_word(&f.editor));
  CHECK(expect_text(&f, "alpha gamma") == 0);
  CHECK(expect_cursor(&f.editor, 0, 6, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_multi_cursor_word_delete(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa bb\ncc dd"));
  CHECK(editor_set_cursor(&f.editor, 2, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 8, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_backspace_word(&f.editor));
  CHECK(expect_text(&f, " bb\n dd") == 0);
  CHECK(expect_cursor(&f.editor, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 1, 4, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_word_movement_selection_behavior(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "alpha beta gamma"));
  CHECK(editor_set_cursor(&f.editor, 0, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_word_right(&f.editor, true));
  CHECK(expect_cursor(&f.editor, 0, 5, 0) == 0);
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 5, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_set_cursor(&f.editor, 8, 2));
  CHECK(editor_word_left(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(editor_set_cursor(&f.editor, 2, 8));
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 8, EDITOR_SELECTION_SENTINEL) == 0);
  fixture_dispose(&f);
  return 0;
}

static int test_multi_cursor_word_movement(void) {
  EditorFixture f;
  CHECK(fixture_init(&f, "aa bb\ncc dd"));
  CHECK(editor_set_cursor(&f.editor, 0, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_add_cursor(&f.editor, 6, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_word_right(&f.editor, false));
  CHECK(expect_cursor(&f.editor, 0, 2, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&f.editor, 1, 8, EDITOR_SELECTION_SENTINEL) == 0);
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

static int test_registered_editors_track_external_edits_and_snap(void) {
  Buffer buffer;
  BufferManager manager;
  Editor source;
  Editor peer;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);
  CHECK(editor_init(&source, &manager));
  CHECK(editor_init(&peer, &manager));

  CHECK(editor_set_cursor(&source, 1, EDITOR_SELECTION_SENTINEL));
  CHECK(editor_set_cursor(&peer, 5, 2));
  CHECK(editor_insert_buffer(&source, "XX", 2));

  size_t len = 0;
  char *actual = buffer_to_string(&buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == 8);
  CHECK(memcmp(actual, "aXXbcdef", 8) == 0);
  free(actual);
  CHECK(expect_cursor(&source, 0, 3, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&peer, 0, 7, 4) == 0);

  CHECK(editor_undo(&source));
  actual = buffer_to_string(&buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == 6);
  CHECK(memcmp(actual, "abcdef", 6) == 0);
  free(actual);
  CHECK(expect_cursor(&source, 0, 0, EDITOR_SELECTION_SENTINEL) == 0);
  CHECK(expect_cursor(&peer, 0, 5, 2) == 0);

  editor_dispose(&peer);
  editor_dispose(&source);
  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_insert_buffer_at_cursor();
  rc |= test_insert_newline_uses_buffer_line_ending_mode();
  rc |= test_open_line_above_preserves_indent();
  rc |= test_open_line_below_preserves_indent_before_next_line();
  rc |= test_open_line_below_last_line_uses_crlf_and_clears_multi_cursors();
  rc |= test_insert_replaces_selection();
  rc |= test_backspace_and_delete();
  rc |= test_delete_line();
  rc |= test_delete_final_crlf_line_removes_previous_line_ending();
  rc |= test_delete_line_removes_selected_line_span();
  rc |= test_multi_cursor_delete_line_merges_overlapping_line_ranges();
  rc |= test_backspace_removes_selection();
  rc |= test_multi_cursor_insert_uses_pre_edit_coordinates();
  rc |= test_multi_cursor_backspace();
  rc |= test_select_all_and_replace();
  rc |= test_select_word();
  rc |= test_select_line();
  rc |= test_selection_to_string();
  rc |= test_selection_to_string_uses_crlf_between_multi_selections();
  rc |= test_left_right_selection_behavior();
  rc |= test_line_start_end_movement();
  rc |= test_end_of_line_stops_before_crlf();
  rc |= test_word_left_right_movement();
  rc |= test_word_delete_commands();
  rc |= test_word_delete_removes_selection();
  rc |= test_multi_cursor_word_delete();
  rc |= test_word_movement_selection_behavior();
  rc |= test_multi_cursor_word_movement();
  rc |= test_line_down_up_preserves_desired_column();
  rc |= test_line_movement_extends_selection();
  rc |= test_editor_undo_redo_places_cursor_at_operation_offset();
  rc |= test_editor_undo_clears_multi_cursors();
  rc |= test_registered_editors_track_external_edits_and_snap();
  return rc;
}
