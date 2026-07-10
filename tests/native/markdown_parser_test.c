#include "markdown_parser.h"
#include "treesitter/languages.h"

#include <tree_sitter/api.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(cond) do { \
  if (!(cond)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    return 1; \
  } \
} while (0)

#define CHECK_STREQ(actual, expected) do { \
  const char *a_ = (actual); \
  const char *e_ = (expected); \
  if (!a_ || strcmp(a_, e_) != 0) { \
    fprintf(stderr, "CHECK_STREQ failed at %s:%d: got '%s', expected '%s'\n", \
      __FILE__, __LINE__, a_ ? a_ : "(null)", e_); \
    return 1; \
  } \
} while (0)

static TSNode find_descendant(TSNode node, const char *type) {
  if (strcmp(ts_node_type(node), type) == 0) return node;
  uint32_t count = ts_node_child_count(node);
  for (uint32_t i = 0; i < count; i++) {
    TSNode found = find_descendant(ts_node_child(node, i), type);
    if (!ts_node_is_null(found)) return found;
  }
  return (TSNode) {0};
}

static unsigned collect_descendants(TSNode node, const char *type, TSNode *out, unsigned capacity) {
  unsigned count = 0;
  if (strcmp(ts_node_type(node), type) == 0) {
    if (count < capacity) out[count] = node;
    return 1;
  }
  uint32_t children = ts_node_child_count(node);
  for (uint32_t i = 0; i < children; i++) {
    TSNode child_nodes[16];
    unsigned child_count = collect_descendants(ts_node_child(node, i), type, child_nodes, 16);
    for (unsigned j = 0; j < child_count; j++) {
      if (count < capacity && j < 16) out[count] = child_nodes[j];
      count++;
    }
  }
  return count;
}

static int test_registry(void) {
  const AnvilTSLanguage *block = anvil_ts_language_by_id("markdown");
  const AnvilTSLanguage *inlines = anvil_ts_language_by_id("markdown_inline");
  CHECK(block != NULL);
  CHECK(inlines != NULL);
  CHECK_STREQ(block->semantic_version, "0.5.3");
  CHECK_STREQ(inlines->semantic_version, "0.5.3");
  CHECK(anvil_ts_language_is_compatible(block));
  CHECK(anvil_ts_language_is_compatible(inlines));
  return 0;
}

static int test_exact_split_ranges(void) {
  const char *source = "# Hello *world*.\n";
  uint32_t source_len = (uint32_t) strlen(source);
  const TSLanguage *block_language = anvil_ts_language_ptr(anvil_ts_language_by_id("markdown"));
  const TSLanguage *inline_language = anvil_ts_language_ptr(anvil_ts_language_by_id("markdown_inline"));

  TSParser *block_parser = ts_parser_new();
  TSParser *inline_parser = ts_parser_new();
  CHECK(block_parser != NULL);
  CHECK(inline_parser != NULL);
  CHECK(ts_parser_set_language(block_parser, block_language));
  CHECK(ts_parser_set_language(inline_parser, inline_language));

  TSTree *block_tree = ts_parser_parse_string(block_parser, NULL, source, source_len);
  CHECK(block_tree != NULL);
  TSNode block_root = ts_tree_root_node(block_tree);
  CHECK(!ts_node_has_error(block_root));

  TSNode marker = find_descendant(block_root, "atx_h1_marker");
  TSNode inline_content = find_descendant(block_root, "inline");
  CHECK(!ts_node_is_null(marker));
  CHECK(!ts_node_is_null(inline_content));
  CHECK(ts_node_start_byte(marker) == 0);
  CHECK(ts_node_end_byte(marker) == 1);
  CHECK(ts_node_start_byte(inline_content) == 2);
  CHECK(ts_node_end_byte(inline_content) == 16);

  TSRange inline_range = {
    .start_point = ts_node_start_point(inline_content),
    .end_point = ts_node_end_point(inline_content),
    .start_byte = ts_node_start_byte(inline_content),
    .end_byte = ts_node_end_byte(inline_content),
  };
  CHECK(ts_parser_set_included_ranges(inline_parser, &inline_range, 1));
  TSTree *inline_tree = ts_parser_parse_string(inline_parser, NULL, source, source_len);
  CHECK(inline_tree != NULL);
  TSNode inline_root = ts_tree_root_node(inline_tree);
  CHECK(!ts_node_has_error(inline_root));

  TSNode emphasis = find_descendant(inline_root, "emphasis");
  CHECK(!ts_node_is_null(emphasis));
  CHECK(ts_node_start_byte(emphasis) == 8);
  CHECK(ts_node_end_byte(emphasis) == 15);

  TSNode delimiters[4];
  unsigned delimiter_count = collect_descendants(emphasis, "emphasis_delimiter", delimiters, 4);
  CHECK(delimiter_count == 2);
  CHECK(ts_node_start_byte(delimiters[0]) == 8);
  CHECK(ts_node_end_byte(delimiters[0]) == 9);
  CHECK(ts_node_start_byte(delimiters[1]) == 14);
  CHECK(ts_node_end_byte(delimiters[1]) == 15);

  ts_tree_delete(inline_tree);
  ts_tree_delete(block_tree);
  ts_parser_delete(inline_parser);
  ts_parser_delete(block_parser);
  return 0;
}

static int test_block_fixture_ranges(void) {
  const char *source =
    "---\n"
    "aliases: [Example]\n"
    "---\n"
    "\n"
    "- [x] Task\n"
    "\n"
    "| A | B |\n"
    "| - | - |\n"
    "| 1 | 2 |\n"
    "\n"
    "<div>**raw**</div>\n";
  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(anvil_ts_language_by_id("markdown"))));
  TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t) strlen(source));
  CHECK(tree != NULL);
  TSNode root = ts_tree_root_node(tree);
  CHECK(!ts_node_has_error(root));
  CHECK(!ts_node_is_null(find_descendant(root, "minus_metadata")));
  CHECK(!ts_node_is_null(find_descendant(root, "task_list_marker_checked")));
  CHECK(!ts_node_is_null(find_descendant(root, "pipe_table")));
  CHECK(!ts_node_is_null(find_descendant(root, "html_block")));
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}

static int test_composite_parser(void) {
  const char *lines[] = {
    "# Hello *world*.\n",
    "Paragraph with **bold**.\n",
    "\n",
    "| A | B |\n",
    "| - | - |\n",
    "| 1 | 2 |\n",
  };
  uint32_t lengths[sizeof(lines) / sizeof(lines[0])];
  for (uint32_t i = 0; i < sizeof(lines) / sizeof(lines[0]); i++) {
    lengths[i] = (uint32_t) strlen(lines[i]);
  }
  char *error = NULL;
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(
    lines,
    lengths,
    (uint32_t) (sizeof(lines) / sizeof(lines[0])),
    &error
  );
  CHECK(snapshot != NULL);
  AnvilMarkdownTree *tree = anvil_markdown_tree_parse(snapshot, 750, NULL, NULL, &error);
  anvil_ts_snapshot_free(snapshot);
  if (!tree) {
    fprintf(stderr, "composite Markdown parse failed: %s\n", error ? error : "unknown");
    free(error);
    return 1;
  }

  uint32_t inline_count = anvil_markdown_tree_inline_count(tree);
  CHECK(inline_count >= 6);
  bool found_emphasis = false;
  bool found_table_cell = false;
  for (uint32_t i = 0; i < inline_count; i++) {
    TSTree *inline_tree = anvil_markdown_tree_inline_tree(tree, i);
    TSRange source_range = anvil_markdown_tree_inline_source_range(tree, i);
    CHECK(inline_tree != NULL);
    CHECK(source_range.end_byte > source_range.start_byte);
    TSNode root = ts_tree_root_node(inline_tree);
    TSNode emphasis = find_descendant(root, "emphasis");
    if (!ts_node_is_null(emphasis) && ts_node_start_byte(emphasis) == 8 && ts_node_end_byte(emphasis) == 15) {
      found_emphasis = true;
    }
    if (source_range.start_point.row >= 3) found_table_cell = true;
  }
  CHECK(found_emphasis);
  CHECK(found_table_cell);
  anvil_markdown_tree_free(tree);
  return 0;
}

static double elapsed_ms(clock_t start) {
  return (double) (clock() - start) * 1000.0 / (double) CLOCKS_PER_SEC;
}

static int test_bounded_large_parse(void) {
  const char *line = "## Heading with **bold**, *italic*, [link](note.md), and `code`.\n";
  size_t line_len = strlen(line);
  size_t target_bytes = 1024 * 1024;
  size_t repeat = target_bytes / line_len + 1;
  size_t source_len = line_len * repeat;
  CHECK(source_len <= UINT32_MAX);
  char *source = (char *) malloc(source_len);
  CHECK(source != NULL);
  for (size_t i = 0; i < repeat; i++) memcpy(source + i * line_len, line, line_len);

  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(anvil_ts_language_by_id("markdown"))));
  clock_t started = clock();
  TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t) source_len);
  double parse_ms = elapsed_ms(started);
  CHECK(tree != NULL);

  TSInputEdit edit = {
    .start_byte = 3,
    .old_end_byte = 4,
    .new_end_byte = 4,
    .start_point = { 0, 3 },
    .old_end_point = { 0, 4 },
    .new_end_point = { 0, 4 },
  };
  ts_tree_edit(tree, &edit);
  source[3] = 'h';
  started = clock();
  TSTree *updated = ts_parser_parse_string(parser, tree, source, (uint32_t) source_len);
  double incremental_ms = elapsed_ms(started);
  CHECK(updated != NULL);
  printf("tree-sitter-markdown block parse: bytes=%zu full_ms=%.3f incremental_ms=%.3f\n",
    source_len, parse_ms, incremental_ms);

  ts_tree_delete(updated);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  free(source);
  return 0;
}

int main(void) {
  if (test_registry() != 0) return 1;
  if (test_exact_split_ranges() != 0) return 1;
  if (test_block_fixture_ranges() != 0) return 1;
  if (test_composite_parser() != 0) return 1;
  if (test_bounded_large_parse() != 0) return 1;
  return 0;
}
