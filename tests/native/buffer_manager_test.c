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
  CHECK(!buffer_is_dirty(&buffer));

  size_t len = 0;
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
  CHECK(buffer_is_dirty(&buffer));
  CHECK(expect_buffer_text(&buffer, "aXYZc\ndef") == 0);

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
  CHECK(expect_buffer_text(&buffer, "aXc\ndYYf\ngZZZi") == 0);

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
  CHECK(expect_buffer_text(&buffer, "bcdef!") == 0);

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

  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_buffer_read_apis();
  rc |= test_apply_single_batch_edit();
  rc |= test_apply_multiple_pre_edit_coordinate_edits();
  rc |= test_rejects_overlaps_atomically();
  rc |= test_rejects_duplicate_zero_width_edits();
  rc |= test_remove_and_insert_boundaries();
  rc |= test_changed_line_ranges_for_newline_insert();
  rc |= test_changed_line_ranges_for_multiline_remove();
  return rc;
}
