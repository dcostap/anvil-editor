#include "text/buffer.h"
#include "text/buffer_manager.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond) do { \
  if (!(cond)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    return 1; \
  } \
} while (0)

static int expect_buffer_text(Buffer *buffer, const char *expected) {
  size_t len = 0;
  char *actual = buffer_to_string(buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == strlen(expected));
  CHECK(memcmp(actual, expected, len) == 0);
  free(actual);
  return 0;
}

static int test_buffer_read_apis(void) {
  Buffer buffer;
  CHECK(buffer_init(&buffer, "alpha\nbeta\ngamma", 16));
  CHECK(buffer_len(&buffer) == 16);
  CHECK(buffer_line_count(&buffer) == 3);
  CHECK(buffer_line_ending_mode(&buffer) == BUFFER_LINE_ENDING_LF);
  size_t newline_len = 0;
  const char *newline = buffer_line_ending_bytes(&buffer, &newline_len);
  CHECK(newline_len == 1);
  CHECK(memcmp(newline, "\n", 1) == 0);
  CHECK(!buffer_is_dirty(&buffer));

  size_t len = 0;
  char *range = buffer_range_to_string(&buffer, 6, 10, &len);
  CHECK(range != NULL);
  CHECK(len == 4);
  CHECK(memcmp(range, "beta", 4) == 0);
  free(range);

  char *line = buffer_get_line(&buffer, 1, &len);
  CHECK(line != NULL);
  CHECK(len == 5);
  CHECK(memcmp(line, "beta\n", 5) == 0);
  free(line);

  line = buffer_get_line(&buffer, 2, &len);
  CHECK(line != NULL);
  CHECK(len == 5);
  CHECK(memcmp(line, "gamma", 5) == 0);
  free(line);

  size_t offset = 0;
  CHECK(buffer_line_col_to_offset(&buffer, 2, 3, &offset));
  CHECK(offset == 14);

  BufferLineCol lc;
  CHECK(buffer_offset_to_line_col(&buffer, 14, &lc));
  CHECK(lc.line == 2 && lc.col == 3);

  buffer_dispose(&buffer);
  return 0;
}

static int test_buffer_detects_crlf_line_endings(void) {
  Buffer buffer;
  CHECK(buffer_init(&buffer, "alpha\r\nbeta", 11));
  CHECK(buffer_line_ending_mode(&buffer) == BUFFER_LINE_ENDING_CRLF);
  size_t newline_len = 0;
  const char *newline = buffer_line_ending_bytes(&buffer, &newline_len);
  CHECK(newline_len == 2);
  CHECK(memcmp(newline, "\r\n", 2) == 0);
  CHECK(buffer_load_bytes(&buffer, "alpha\nbeta", 10));
  CHECK(buffer_line_ending_mode(&buffer) == BUFFER_LINE_ENDING_LF);
  buffer_dispose(&buffer);
  return 0;
}

static int test_buffer_path_is_owned_and_reset_on_load(void) {
  Buffer buffer;
  CHECK(buffer_init(&buffer, "abc", 3));
  char path[] = "C:/tmp/example.txt";
  CHECK(buffer_set_path(&buffer, path));
  path[7] = 'X';
  CHECK(buffer_path(&buffer) != NULL);
  CHECK(strcmp(buffer_path(&buffer), "C:/tmp/example.txt") == 0);
  CHECK(buffer_set_path(&buffer, "D:/other.txt"));
  CHECK(strcmp(buffer_path(&buffer), "D:/other.txt") == 0);
  CHECK(buffer_load_bytes(&buffer, "def", 3));
  CHECK(buffer_path(&buffer) == NULL);
  buffer_dispose(&buffer);
  return 0;
}

static int test_buffer_load_file_preserves_bytes_and_sets_path(void) {
  const char *path = "buffer_load_file_test.tmp";
  const char bytes[] = { 'a', '\0', 'b', '\r', '\n' };
  FILE *file = fopen(path, "wb");
  CHECK(file != NULL);
  CHECK(fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes));
  CHECK(fclose(file) == 0);

  Buffer buffer;
  CHECK(buffer_init(&buffer, "old", 3));
  CHECK(buffer_load_file(&buffer, path));
  CHECK(buffer_path(&buffer) != NULL);
  CHECK(strcmp(buffer_path(&buffer), path) == 0);
  CHECK(buffer_line_ending_mode(&buffer) == BUFFER_LINE_ENDING_CRLF);
  size_t len = 0;
  char *actual = buffer_to_string(&buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == sizeof(bytes));
  CHECK(memcmp(actual, bytes, sizeof(bytes)) == 0);
  free(actual);
  buffer_dispose(&buffer);
  CHECK(remove(path) == 0);
  return 0;
}

static int test_apply_single_batch_edit(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abc\ndef", 7));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edit = { 1, 2, "XYZ", 3, 0 };
  BatchEditResult result = buffer_manager_apply_edits(&manager, &edit, 1);
  CHECK(result.applied);
  CHECK(!result.rejected);
  CHECK(result.edit_count == 1);
  CHECK(result.changed_start == 1);
  CHECK(result.changed_old_end == 2);
  CHECK(result.changed_new_end == 4);
  CHECK(result.changed_old_start_line == 0);
  CHECK(result.changed_old_end_line == 1);
  CHECK(result.changed_new_start_line == 0);
  CHECK(result.changed_new_end_line == 1);
  CHECK(result.cursor_mapping_count == 1);
  CHECK(result.cursor_mappings[0].cursor_index == 0);
  CHECK(result.cursor_mappings[0].old_start_offset == 1);
  CHECK(result.cursor_mappings[0].old_end_offset == 2);
  CHECK(result.cursor_mappings[0].new_start_offset == 1);
  CHECK(result.cursor_mappings[0].new_end_offset == 4);
  CHECK(result.cursor_mappings[0].new_cursor_offset == 4);
  CHECK(buffer_is_dirty(&buffer));
  CHECK(expect_buffer_text(&buffer, "aXYZc\ndef") == 0);
  batch_edit_result_dispose(&result);

  buffer_mark_clean(&buffer);
  CHECK(!buffer_is_dirty(&buffer));

  buffer_dispose(&buffer);
  return 0;
}

static int test_apply_multiple_pre_edit_coordinate_edits(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abc\ndef\nghi", 11));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edits[] = {
    { 1, 2, "X", 1, 0 },
    { 5, 6, "YY", 2, 1 },
    { 9, 10, "ZZZ", 3, 2 },
  };
  BatchEditResult result = buffer_manager_apply_edits(&manager, edits, 3);
  CHECK(result.applied);
  CHECK(result.changed_start == 1);
  CHECK(result.changed_old_end == 10);
  CHECK(result.changed_new_end == 13);
  CHECK(result.changed_old_start_line == 0);
  CHECK(result.changed_old_end_line == 3);
  CHECK(result.changed_new_start_line == 0);
  CHECK(result.changed_new_end_line == 3);
  CHECK(result.cursor_mapping_count == 3);
  CHECK(result.cursor_mappings[0].cursor_index == 0);
  CHECK(result.cursor_mappings[0].new_cursor_offset == 2);
  CHECK(result.cursor_mappings[1].cursor_index == 1);
  CHECK(result.cursor_mappings[1].new_cursor_offset == 7);
  CHECK(result.cursor_mappings[2].cursor_index == 2);
  CHECK(result.cursor_mappings[2].new_cursor_offset == 13);
  CHECK(expect_buffer_text(&buffer, "aXc\ndYYf\ngZZZi") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

static int test_rejects_overlaps_atomically(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edits[] = {
    { 1, 4, "X", 1, 0 },
    { 3, 5, "Y", 1, 1 },
  };
  BatchEditResult result = buffer_manager_apply_edits(&manager, edits, 2);
  CHECK(!result.applied);
  CHECK(result.rejected);
  CHECK(!buffer_is_dirty(&buffer));
  CHECK(expect_buffer_text(&buffer, "abcdef") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

static int test_rejects_duplicate_zero_width_edits(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edits[] = {
    { 2, 2, "X", 1, 0 },
    { 2, 2, "Y", 1, 1 },
  };
  BatchEditResult result = buffer_manager_apply_edits(&manager, edits, 2);
  CHECK(!result.applied);
  CHECK(result.rejected);
  CHECK(expect_buffer_text(&buffer, "abcdef") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

static int test_remove_and_insert_boundaries(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edits[] = {
    { 0, 1, "", 0, 0 },
    { 6, 6, "!", 1, 1 },
  };
  BatchEditResult result = buffer_manager_apply_edits(&manager, edits, 2);
  CHECK(result.applied);
  CHECK(result.cursor_mapping_count == 2);
  CHECK(result.cursor_mappings[0].cursor_index == 0);
  CHECK(result.cursor_mappings[0].new_cursor_offset == 0);
  CHECK(result.cursor_mappings[1].cursor_index == 1);
  CHECK(result.cursor_mappings[1].new_cursor_offset == 6);
  CHECK(expect_buffer_text(&buffer, "bcdef!") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

static int test_changed_line_ranges_for_newline_insert(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edit = { 3, 3, "\nXY\n", 4, 0 };
  BatchEditResult result = buffer_manager_apply_edits(&manager, &edit, 1);
  CHECK(result.applied);
  CHECK(result.changed_start == 3);
  CHECK(result.changed_old_end == 3);
  CHECK(result.changed_new_end == 7);
  CHECK(result.changed_old_start_line == 0);
  CHECK(result.changed_old_end_line == 1);
  CHECK(result.changed_new_start_line == 0);
  CHECK(result.changed_new_end_line == 2);
  CHECK(expect_buffer_text(&buffer, "abc\nXY\ndef") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

static int test_changed_line_ranges_for_multiline_remove(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "aa\nbb\ncc\ndd", 11));
  buffer_manager_init(&manager, &buffer);

  BatchEditItem edit = { 2, 8, "", 0, 0 };
  BatchEditResult result = buffer_manager_apply_edits(&manager, &edit, 1);
  CHECK(result.applied);
  CHECK(result.changed_start == 2);
  CHECK(result.changed_old_end == 8);
  CHECK(result.changed_new_end == 2);
  CHECK(result.changed_old_start_line == 0);
  CHECK(result.changed_old_end_line == 3);
  CHECK(result.changed_new_start_line == 0);
  CHECK(result.changed_new_end_line == 1);
  CHECK(expect_buffer_text(&buffer, "aa\ndd") == 0);
  batch_edit_result_dispose(&result);

  buffer_dispose(&buffer);
  return 0;
}

typedef struct ListenerProbe {
  int edit_count;
  int snap_count;
  void *last_source;
  size_t last_changed_start;
  size_t last_changed_old_end;
  size_t last_changed_new_end;
} ListenerProbe;

static void probe_on_edit(void *user, const BatchEditResult *result, void *source) {
  ListenerProbe *probe = (ListenerProbe *) user;
  ++probe->edit_count;
  probe->last_source = source;
  probe->last_changed_start = result->changed_start;
  probe->last_changed_old_end = result->changed_old_end;
  probe->last_changed_new_end = result->changed_new_end;
}

static void probe_on_snap(void *user, const BufferSnapResult *result, void *source) {
  ListenerProbe *probe = (ListenerProbe *) user;
  ++probe->snap_count;
  probe->last_source = source;
  probe->last_changed_start = result->changed_start;
  probe->last_changed_old_end = result->changed_old_end;
  probe->last_changed_new_end = result->changed_new_end;
}

static int test_registered_listener_receives_edit_and_snap_notifications(void) {
  Buffer buffer;
  BufferManager manager;
  ListenerProbe probe = { 0 };
  int source_token = 0;
  CHECK(buffer_init(&buffer, "abcdef", 6));
  buffer_manager_init(&manager, &buffer);
  CHECK(buffer_manager_register_listener(&manager, &probe, probe_on_edit, probe_on_snap));

  BatchEditItem edit = { 1, 3, "XY", 2, 0 };
  BatchEditResult result = buffer_manager_apply_edits_from(&manager, &edit, 1, &source_token);
  CHECK(result.applied);
  CHECK(probe.edit_count == 1);
  CHECK(probe.last_source == &source_token);
  CHECK(probe.last_changed_start == 1);
  CHECK(probe.last_changed_old_end == 3);
  CHECK(probe.last_changed_new_end == 3);
  CHECK(expect_buffer_text(&buffer, "aXYdef") == 0);
  batch_edit_result_dispose(&result);

  size_t op_offset = 999;
  CHECK(buffer_manager_undo_from(&manager, &op_offset, &source_token));
  CHECK(op_offset == 0);
  CHECK(probe.snap_count == 1);
  CHECK(probe.last_source == &source_token);
  CHECK(probe.last_changed_start == 1);
  CHECK(probe.last_changed_old_end == 3);
  CHECK(probe.last_changed_new_end == 3);
  CHECK(expect_buffer_text(&buffer, "abcdef") == 0);

  buffer_manager_unregister_listener(&manager, &probe);
  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_buffer_read_apis();
  rc |= test_buffer_detects_crlf_line_endings();
  rc |= test_buffer_path_is_owned_and_reset_on_load();
  rc |= test_buffer_load_file_preserves_bytes_and_sets_path();
  rc |= test_apply_single_batch_edit();
  rc |= test_apply_multiple_pre_edit_coordinate_edits();
  rc |= test_rejects_overlaps_atomically();
  rc |= test_rejects_duplicate_zero_width_edits();
  rc |= test_remove_and_insert_boundaries();
  rc |= test_changed_line_ranges_for_newline_insert();
  rc |= test_changed_line_ranges_for_multiline_remove();
  rc |= test_registered_listener_receives_edit_and_snap_notifications();
  return rc;
}
