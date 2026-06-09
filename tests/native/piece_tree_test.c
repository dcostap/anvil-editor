#include "text/piece_tree.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond) do { \
  if (!(cond)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    return 1; \
  } \
} while (0)

static int expect_text(PieceTree *tree, const char *expected) {
  size_t len = 0;
  char *actual = piece_tree_to_string(tree, &len);
  CHECK(actual != NULL);
  CHECK(len == strlen(expected));
  CHECK(memcmp(actual, expected, len) == 0);
  free(actual);
  CHECK(piece_tree_check_invariants(tree));
  return 0;
}

static int test_basic_insert_remove(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "hello", 5));
  CHECK(expect_text(&tree, "hello") == 0);

  CHECK(piece_tree_insert(&tree, 5, " world", 6));
  CHECK(expect_text(&tree, "hello world") == 0);

  CHECK(piece_tree_insert(&tree, 0, "Say: ", 5));
  CHECK(expect_text(&tree, "Say: hello world") == 0);

  CHECK(piece_tree_insert(&tree, 11, "big ", 4));
  CHECK(expect_text(&tree, "Say: hello big world") == 0);

  CHECK(piece_tree_remove(&tree, 5, 6));
  CHECK(expect_text(&tree, "Say: big world") == 0);

  CHECK(piece_tree_remove(&tree, 0, piece_tree_len(&tree)));
  CHECK(expect_text(&tree, "") == 0);

  piece_tree_dispose(&tree);
  return 0;
}

static int test_line_lookup(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "alpha\nbeta\ngamma", 16));
  CHECK(piece_tree_line_count(&tree) == 3);

  size_t offset = 999;
  CHECK(piece_tree_line_start(&tree, 0, &offset));
  CHECK(offset == 0);
  CHECK(piece_tree_line_start(&tree, 1, &offset));
  CHECK(offset == 6);
  CHECK(piece_tree_line_start(&tree, 2, &offset));
  CHECK(offset == 11);
  CHECK(!piece_tree_line_start(&tree, 3, &offset));

  PieceTreeLineCol lc;
  CHECK(piece_tree_offset_to_line_col(&tree, 0, &lc));
  CHECK(lc.line == 0 && lc.col == 0);
  CHECK(piece_tree_offset_to_line_col(&tree, 8, &lc));
  CHECK(lc.line == 1 && lc.col == 2);
  CHECK(piece_tree_offset_to_line_col(&tree, 16, &lc));
  CHECK(lc.line == 2 && lc.col == 5);

  CHECK(piece_tree_line_col_to_offset(&tree, 1, 2, &offset));
  CHECK(offset == 8);
  CHECK(!piece_tree_line_col_to_offset(&tree, 1, 99, &offset));

  CHECK(piece_tree_insert(&tree, 6, "BIG\n", 4));
  CHECK(expect_text(&tree, "alpha\nBIG\nbeta\ngamma") == 0);
  CHECK(piece_tree_line_count(&tree) == 4);
  CHECK(piece_tree_line_start(&tree, 2, &offset));
  CHECK(offset == 10);

  piece_tree_dispose(&tree);
  return 0;
}

static int test_trailing_newline_line(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "a\n", 2));
  CHECK(piece_tree_line_count(&tree) == 2);
  size_t offset = 999;
  CHECK(piece_tree_line_start(&tree, 1, &offset));
  CHECK(offset == 2);
  CHECK(piece_tree_line_col_to_offset(&tree, 1, 0, &offset));
  CHECK(offset == 2);
  CHECK(!piece_tree_line_col_to_offset(&tree, 1, 1, &offset));
  piece_tree_dispose(&tree);
  return 0;
}

static int test_crlf_and_bytes_are_preserved(void) {
  const char bytes[] = { 'a', '\r', '\n', 'b', '\n', (char)0xff, 'z' };
  PieceTree tree;
  CHECK(piece_tree_init(&tree, bytes, sizeof(bytes)));
  CHECK(piece_tree_lf_count(&tree) == 2);
  CHECK(piece_tree_line_count(&tree) == 3);
  CHECK(piece_tree_insert(&tree, 3, "\xce\xbb", 2));
  CHECK(piece_tree_remove(&tree, 5, 1));

  const char expected[] = { 'a', '\r', '\n', (char)0xce, (char)0xbb, '\n', (char)0xff, 'z' };
  size_t len = 0;
  char *actual = piece_tree_to_string(&tree, &len);
  CHECK(actual != NULL);
  CHECK(len == sizeof(expected));
  CHECK(memcmp(actual, expected, sizeof(expected)) == 0);
  free(actual);
  CHECK(piece_tree_check_invariants(&tree));
  piece_tree_dispose(&tree);
  return 0;
}

static int test_line_ranges_and_crlf_line_end(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "a\r\nb\nc\rx", 8));

  PieceTreeLineRange range;
  CHECK(piece_tree_line_range_with_newline(&tree, 0, &range));
  CHECK(range.start == 0 && range.end == 3);
  CHECK(piece_tree_line_range(&tree, 0, &range));
  CHECK(range.start == 0 && range.end == 2);
  CHECK(piece_tree_line_range_crlf(&tree, 0, &range));
  CHECK(range.start == 0 && range.end == 1);

  CHECK(piece_tree_line_range_with_newline(&tree, 1, &range));
  CHECK(range.start == 3 && range.end == 5);
  CHECK(piece_tree_line_range(&tree, 1, &range));
  CHECK(range.start == 3 && range.end == 4);
  CHECK(piece_tree_line_range_crlf(&tree, 1, &range));
  CHECK(range.start == 3 && range.end == 4);

  CHECK(piece_tree_line_range_with_newline(&tree, 2, &range));
  CHECK(range.start == 5 && range.end == 8);
  CHECK(piece_tree_line_range(&tree, 2, &range));
  CHECK(range.start == 5 && range.end == 8);
  CHECK(piece_tree_line_range_crlf(&tree, 2, &range));
  CHECK(range.start == 5 && range.end == 8);
  CHECK(!piece_tree_line_range(&tree, 3, &range));

  piece_tree_dispose(&tree);
  return 0;
}

static int test_snapshot_restore(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "one\ntwo", 7));
  PieceTreeSnapshot before = piece_tree_snapshot_acquire(&tree);

  CHECK(piece_tree_insert(&tree, 3, " plus", 5));
  CHECK(expect_text(&tree, "one plus\ntwo") == 0);

  PieceTreeSnapshot middle = piece_tree_snapshot_acquire(&tree);
  CHECK(piece_tree_remove(&tree, 0, 4));
  CHECK(expect_text(&tree, "plus\ntwo") == 0);

  CHECK(piece_tree_restore_snapshot(&tree, &before));
  CHECK(expect_text(&tree, "one\ntwo") == 0);

  CHECK(piece_tree_restore_snapshot(&tree, &middle));
  CHECK(expect_text(&tree, "one plus\ntwo") == 0);

  piece_tree_snapshot_release(&before);
  piece_tree_snapshot_release(&middle);
  piece_tree_dispose(&tree);
  return 0;
}

static int test_text_snapshot_stays_stable_after_edits(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "alpha\nbeta\n", 11));
  CHECK(piece_tree_insert(&tree, 6, "old ", 4));

  PieceTreeTextSnapshot snapshot;
  CHECK(piece_tree_text_snapshot_acquire(&tree, &snapshot));
  CHECK(piece_tree_text_snapshot_len(&snapshot) == 15);

  CHECK(piece_tree_remove(&tree, 0, piece_tree_len(&tree)));
  CHECK(piece_tree_insert(&tree, 0, "new text", 8));
  CHECK(expect_text(&tree, "new text") == 0);

  size_t len = 0;
  char *snapshot_text = piece_tree_text_snapshot_range_to_string(&snapshot, 0, piece_tree_text_snapshot_len(&snapshot), &len);
  CHECK(snapshot_text != NULL);
  CHECK(len == 15);
  CHECK(memcmp(snapshot_text, "alpha\nold beta\n", 15) == 0);
  free(snapshot_text);

  piece_tree_text_snapshot_release(&snapshot);
  piece_tree_dispose(&tree);
  return 0;
}

static int test_byte_at_and_walkers(void) {
  PieceTree tree;
  CHECK(piece_tree_init(&tree, "abcd", 4));
  CHECK(piece_tree_insert(&tree, 2, "XY", 2));
  CHECK(piece_tree_remove(&tree, 0, 1));
  CHECK(expect_text(&tree, "bXYcd") == 0);

  char ch = 0;
  CHECK(piece_tree_byte_at(&tree, 0, &ch));
  CHECK(ch == 'b');
  CHECK(piece_tree_byte_at(&tree, 2, &ch));
  CHECK(ch == 'Y');
  CHECK(!piece_tree_byte_at(&tree, piece_tree_len(&tree), &ch));

  size_t range_len = 0;
  char *range = piece_tree_range_to_string(&tree, 1, 4, &range_len);
  CHECK(range != NULL);
  CHECK(range_len == 3);
  CHECK(memcmp(range, "XYc", 3) == 0);
  free(range);
  CHECK(!piece_tree_range_to_string(&tree, 4, 99, &range_len));

  PieceTreeWalker walker;
  CHECK(piece_tree_walker_init(&walker, &tree, 1));
  char forward[8];
  size_t offsets[8];
  size_t count = 0;
  while (piece_tree_walker_next(&walker, &ch, &offsets[count])) {
    forward[count++] = ch;
  }
  CHECK(count == 4);
  CHECK(memcmp(forward, "XYcd", 4) == 0);
  CHECK(offsets[0] == 1);
  CHECK(offsets[3] == 4);

  CHECK(piece_tree_reverse_walker_init(&walker, &tree, piece_tree_len(&tree)));
  char reverse[8];
  count = 0;
  while (piece_tree_walker_prev(&walker, &ch, &offsets[count])) {
    reverse[count++] = ch;
  }
  CHECK(count == 5);
  CHECK(memcmp(reverse, "dcYXb", 5) == 0);
  CHECK(offsets[0] == 4);
  CHECK(offsets[4] == 0);

  piece_tree_dispose(&tree);
  return 0;
}

typedef struct FlatString {
  char *data;
  size_t len;
  size_t cap;
} FlatString;

static bool flat_reserve(FlatString *s, size_t needed) {
  if (needed <= s->cap) return true;
  size_t cap = s->cap ? s->cap : 64;
  while (cap < needed) cap *= 2;
  char *data = (char *) realloc(s->data, cap);
  if (!data) return false;
  s->data = data;
  s->cap = cap;
  return true;
}

static bool flat_insert(FlatString *s, size_t offset, const char *text, size_t len) {
  if (offset > s->len) return false;
  if (!flat_reserve(s, s->len + len)) return false;
  memmove(s->data + offset + len, s->data + offset, s->len - offset);
  memcpy(s->data + offset, text, len);
  s->len += len;
  return true;
}

static bool flat_remove(FlatString *s, size_t offset, size_t len) {
  if (offset > s->len || len > s->len - offset) return false;
  memmove(s->data + offset, s->data + offset + len, s->len - offset - len);
  s->len -= len;
  return true;
}

static uint32_t fuzz_next(uint32_t *state) {
  uint32_t x = *state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *state = x;
  return x;
}

static int compare_line_metadata_to_flat(PieceTree *tree, const FlatString *flat) {
  size_t line_count = 1;
  for (size_t i = 0; i < flat->len; ++i) {
    if (flat->data[i] == '\n') ++line_count;
  }
  CHECK(piece_tree_line_count(tree) == line_count);
  CHECK(piece_tree_lf_count(tree) + 1 == line_count);

  size_t *line_starts = (size_t *) malloc(sizeof(size_t) * line_count);
  CHECK(line_starts != NULL);
  size_t line = 0;
  line_starts[line++] = 0;
  for (size_t i = 0; i < flat->len; ++i) {
    if (flat->data[i] == '\n') line_starts[line++] = i + 1;
  }
  CHECK(line == line_count);

  for (size_t i = 0; i < line_count; ++i) {
    size_t offset = SIZE_MAX;
    CHECK(piece_tree_line_start(tree, i, &offset));
    CHECK(offset == line_starts[i]);
  }
  size_t invalid_offset = 0;
  CHECK(!piece_tree_line_start(tree, line_count, &invalid_offset));

  for (size_t offset = 0; offset <= flat->len; ++offset) {
    size_t expected_line = 0;
    while (expected_line + 1 < line_count && line_starts[expected_line + 1] <= offset) {
      ++expected_line;
    }
    size_t expected_col = offset - line_starts[expected_line];
    PieceTreeLineCol lc;
    CHECK(piece_tree_offset_to_line_col(tree, offset, &lc));
    CHECK(lc.line == expected_line);
    CHECK(lc.col == expected_col);

    size_t line_end = expected_line + 1 < line_count
      ? line_starts[expected_line + 1] - 1
      : flat->len;
    if (offset <= line_end) {
      size_t roundtrip = SIZE_MAX;
      CHECK(piece_tree_line_col_to_offset(tree, lc.line, lc.col, &roundtrip));
      CHECK(roundtrip == offset);
    }
  }

  free(line_starts);
  return 0;
}

static int compare_tree_to_flat(PieceTree *tree, const FlatString *flat) {
  size_t len = 0;
  char *actual = piece_tree_to_string(tree, &len);
  CHECK(actual != NULL);
  CHECK(len == flat->len);
  CHECK(memcmp(actual, flat->data, flat->len) == 0);
  free(actual);
  CHECK(piece_tree_check_invariants(tree));
  CHECK(compare_line_metadata_to_flat(tree, flat) == 0);
  return 0;
}

static int test_random_edits_against_flat_oracle(void) {
  PieceTree tree;
  FlatString flat = { 0 };
  const char *initial = "first\nsecond\nthird";
  CHECK(piece_tree_init(&tree, initial, strlen(initial)));
  CHECK(flat_insert(&flat, 0, initial, strlen(initial)));

  uint32_t rng = 0xabcdef01u;
  for (size_t step = 0; step < 2000; ++step) {
    uint32_t choice = fuzz_next(&rng);
    if ((choice & 3u) != 0 || flat.len == 0) {
      char text[16];
      size_t len = 1 + (fuzz_next(&rng) % sizeof(text));
      for (size_t i = 0; i < len; ++i) {
        uint32_t r = fuzz_next(&rng);
        text[i] = (r % 11u) == 0 ? '\n' : (char)('a' + (r % 26u));
      }
      size_t offset = flat.len == 0 ? 0 : fuzz_next(&rng) % (flat.len + 1);
      CHECK(piece_tree_insert(&tree, offset, text, len));
      CHECK(flat_insert(&flat, offset, text, len));
    } else {
      size_t offset = fuzz_next(&rng) % flat.len;
      size_t max_len = flat.len - offset;
      size_t len = 1 + (fuzz_next(&rng) % max_len);
      if (len > 24) len = 24;
      CHECK(piece_tree_remove(&tree, offset, len));
      CHECK(flat_remove(&flat, offset, len));
    }

    if (compare_tree_to_flat(&tree, &flat) != 0) return 1;
  }

  free(flat.data);
  piece_tree_dispose(&tree);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_basic_insert_remove();
  rc |= test_line_lookup();
  rc |= test_trailing_newline_line();
  rc |= test_crlf_and_bytes_are_preserved();
  rc |= test_line_ranges_and_crlf_line_end();
  rc |= test_snapshot_restore();
  rc |= test_text_snapshot_stays_stable_after_edits();
  rc |= test_byte_at_and_walkers();
  rc |= test_random_edits_against_flat_oracle();
  return rc;
}
