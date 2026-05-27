#include "fuzzy.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond) do { \
  if (!(cond)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    return 1; \
  } \
} while (0)

static int find_text(const FuzzyIndex *idx, FuzzySearchResult *results, uint32_t count, const char *text) {
  for (uint32_t i = 0; i < count; ++i) {
    if (strcmp(fuzzy_index_text(idx, results[i].entry_index), text) == 0) return (int)i;
  }
  return -1;
}

static int test_generic_basic(void) {
  const char *items[] = { "core:open-file", "close-window", "save-all" };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_GENERIC));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "opf", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count >= 1);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "core:open-file") == 0);
  CHECK(r[0].source_index == 1);
  CHECK(!has_more);
  free(r);

  r = fuzzy_index_search(&idx, "zzzz", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_case_insensitive_and_limit(void) {
  const char *items[] = { "Alpha", "alphabet", "beta" };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_GENERIC));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "AL", 1, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 1);
  CHECK(has_more);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "Alpha") == 0 ||
        strcmp(fuzzy_index_text(&idx, r[0].entry_index), "alphabet") == 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_path_basename_preference(void) {
  const char *items[] = {
    "src/render/backend.c",
    "renderer.c",
    "docs/renderer_notes.txt"
  };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_PATH));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "renderer", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count >= 2);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "renderer.c") == 0);
  CHECK(find_text(&idx, r, count, "docs/renderer_notes.txt") >= 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_contiguous_match_beats_split_subsequence(void) {
  const char *items[] = {
    "game/c_foo_inematic.cpp",
    "game/cinematic.cpp",
    "game/cutscene_cinematic_helper.cpp"
  };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_PATH));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "cinematic", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 3);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "game/cinematic.cpp") == 0);
  CHECK(find_text(&idx, r, count, "game/c_foo_inematic.cpp") > 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_extending_exact_query_keeps_exact_match_on_top(void) {
  const char *items[] = {
    "physics/k_foo_inematics.cpp",
    "physics/kinematics.cpp",
    "physics/kinematics.h"
  };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_PATH));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "kinematic", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 3);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "physics/kinematics.cpp") == 0 ||
        strcmp(fuzzy_index_text(&idx, r[0].entry_index), "physics/kinematics.h") == 0);
  free(r);

  r = fuzzy_index_search(&idx, "kinematics", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 3);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "physics/kinematics.cpp") == 0 ||
        strcmp(fuzzy_index_text(&idx, r[0].entry_index), "physics/kinematics.h") == 0);
  CHECK(find_text(&idx, r, count, "physics/k_foo_inematics.cpp") > 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_spans(void) {
  const char *items[] = { "src/main_file.c" };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 1, FUZZY_MODE_PATH));

  FuzzySpan spans[8];
  uint32_t n = fuzzy_match_spans(&idx, 0, "main", spans, 8);
  CHECK(n == 1);
  CHECK(spans[0].start == 5);
  CHECK(spans[0].end == 8);

  n = fuzzy_match_spans(&idx, 0, "srf", spans, 8);
  CHECK(n >= 2);
  CHECK(spans[0].start == 1);

  const FuzzyEntry *e = &idx.entries[0];
  n = fuzzy_match_text_spans(idx.lower_arena + e->lower_offset, e->len, "main", spans, 8);
  CHECK(n == 1);
  CHECK(spans[0].start == 5);
  CHECK(spans[0].end == 8);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_limit_zero(void) {
  const char *items[] = { "Alpha", "alphabet", "beta" };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 3, FUZZY_MODE_GENERIC));

  uint32_t count = 99;
  bool has_more = true;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "a", 0, &count, &has_more);
  CHECK(r == NULL);
  CHECK(count == 0);
  CHECK(!has_more);

  fuzzy_index_free(&idx);
  return 0;
}

static int test_empty_query_deterministic(void) {
  const char *items[] = { "b", "a" };
  FuzzyIndex idx;
  CHECK(fuzzy_index_build(&idx, items, 2, FUZZY_MODE_GENERIC));

  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *r = fuzzy_index_search(&idx, "", 10, &count, &has_more);
  CHECK(r != NULL);
  CHECK(count == 2);
  CHECK(strcmp(fuzzy_index_text(&idx, r[0].entry_index), "a") == 0);
  CHECK(strcmp(fuzzy_index_text(&idx, r[1].entry_index), "b") == 0);
  free(r);

  fuzzy_index_free(&idx);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_generic_basic();
  rc |= test_case_insensitive_and_limit();
  rc |= test_path_basename_preference();
  rc |= test_contiguous_match_beats_split_subsequence();
  rc |= test_extending_exact_query_keeps_exact_match_on_top();
  rc |= test_spans();
  rc |= test_limit_zero();
  rc |= test_empty_query_deterministic();
  return rc;
}
