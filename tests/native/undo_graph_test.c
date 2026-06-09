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

static int expect_text(Buffer *buffer, const char *expected) {
  size_t len = 0;
  char *actual = buffer_to_string(buffer, &len);
  CHECK(actual != NULL);
  CHECK(len == strlen(expected));
  CHECK(memcmp(actual, expected, len) == 0);
  free(actual);
  return 0;
}

static int apply_one(BufferManager *manager, size_t start, size_t end, const char *text) {
  BatchEditItem edit = { start, end, text, text ? strlen(text) : 0, 0 };
  BatchEditResult result = buffer_manager_apply_edits(manager, &edit, 1);
  CHECK(result.applied);
  return 0;
}

static int test_linear_undo_redo(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abc", 3));
  buffer_manager_init(&manager, &buffer);
  CHECK(!buffer_is_dirty(&buffer));
  CHECK(!buffer_can_undo(&buffer));

  CHECK(apply_one(&manager, 3, 3, "d") == 0);
  CHECK(expect_text(&buffer, "abcd") == 0);
  CHECK(buffer_is_dirty(&buffer));
  CHECK(buffer_can_undo(&buffer));
  CHECK(!buffer_can_redo(&buffer));

  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "abc") == 0);
  CHECK(!buffer_is_dirty(&buffer));
  CHECK(!buffer_can_undo(&buffer));
  CHECK(buffer_can_redo(&buffer));

  CHECK(buffer_redo(&buffer));
  CHECK(expect_text(&buffer, "abcd") == 0);
  CHECK(buffer_is_dirty(&buffer));
  CHECK(buffer_can_undo(&buffer));
  CHECK(!buffer_can_redo(&buffer));

  buffer_dispose(&buffer);
  return 0;
}

static int test_multiple_undo_redo_steps(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "", 0));
  buffer_manager_init(&manager, &buffer);

  CHECK(apply_one(&manager, 0, 0, "a") == 0);
  CHECK(apply_one(&manager, 1, 1, "b") == 0);
  CHECK(apply_one(&manager, 2, 2, "c") == 0);
  CHECK(expect_text(&buffer, "abc") == 0);

  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "ab") == 0);
  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "a") == 0);
  CHECK(buffer_redo(&buffer));
  CHECK(expect_text(&buffer, "ab") == 0);
  CHECK(buffer_redo(&buffer));
  CHECK(expect_text(&buffer, "abc") == 0);

  buffer_dispose(&buffer);
  return 0;
}

static int test_branching_redo_uses_latest_child(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "a", 1));
  buffer_manager_init(&manager, &buffer);

  CHECK(apply_one(&manager, 1, 1, "b") == 0);
  CHECK(expect_text(&buffer, "ab") == 0);
  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "a") == 0);

  CHECK(apply_one(&manager, 1, 1, "c") == 0);
  CHECK(expect_text(&buffer, "ac") == 0);
  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "a") == 0);

  /* Fred's try_redo follows children.last, so the newest branch is default. */
  CHECK(buffer_redo(&buffer));
  CHECK(expect_text(&buffer, "ac") == 0);

  buffer_dispose(&buffer);
  return 0;
}

static int test_mark_clean_tracks_current_graph_node(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "abc", 3));
  buffer_manager_init(&manager, &buffer);

  CHECK(apply_one(&manager, 3, 3, "d") == 0);
  CHECK(buffer_is_dirty(&buffer));
  buffer_mark_clean(&buffer);
  CHECK(!buffer_is_dirty(&buffer));

  CHECK(apply_one(&manager, 4, 4, "e") == 0);
  CHECK(buffer_is_dirty(&buffer));
  CHECK(buffer_undo(&buffer));
  CHECK(expect_text(&buffer, "abcd") == 0);
  CHECK(!buffer_is_dirty(&buffer));

  buffer_dispose(&buffer);
  return 0;
}

static int test_update_undo_replaces_current_snapshot(void) {
  Buffer buffer;
  BufferManager manager;
  CHECK(buffer_init(&buffer, "a", 1));
  buffer_manager_init(&manager, &buffer);

  CHECK(apply_one(&manager, 1, 1, "b") == 0);
  CHECK(expect_text(&buffer, "ab") == 0);
  CHECK(piece_tree_insert(&buffer.tree, 2, "c", 1));
  CHECK(buffer_manager_update_undo(&manager, 2));
  CHECK(expect_text(&buffer, "abc") == 0);

  size_t op_offset = 99;
  CHECK(buffer_undo_op_offset(&buffer, &op_offset));
  CHECK(expect_text(&buffer, "a") == 0);
  CHECK(op_offset == 0);
  CHECK(buffer_redo_op_offset(&buffer, &op_offset));
  CHECK(expect_text(&buffer, "abc") == 0);
  CHECK(op_offset == 2);

  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_linear_undo_redo();
  rc |= test_multiple_undo_redo_steps();
  rc |= test_branching_redo_uses_latest_child();
  rc |= test_mark_clean_tracks_current_graph_node();
  rc |= test_update_undo_replaces_current_snapshot();
  return rc;
}
