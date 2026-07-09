#include "markdown_parser.h"

#include "treesitter/languages.h"

#include <SDL3/SDL_timer.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct AnvilMarkdownInlineTree {
  TSTree *tree;
  TSRange source_range;
} AnvilMarkdownInlineTree;

struct AnvilMarkdownTree {
  AnvilTSSnapshot *snapshot;
  TSTree *block_tree;
  AnvilMarkdownInlineTree *inline_trees;
  uint32_t inline_count;
  uint32_t inline_capacity;
};

typedef struct ParseRun {
  uint64_t started_ticks;
  uint32_t timeout_ms;
  bool timed_out;
} ParseRun;

static char *parser_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (copy) memcpy(copy, text, len + 1);
  return copy;
}

static bool parse_progress(TSParseState *state) {
  ParseRun *run = (ParseRun *) state->payload;
  if (!run || run->timeout_ms == 0) return false;
  if (SDL_GetTicks() - run->started_ticks < run->timeout_ms) return false;
  run->timed_out = true;
  return true;
}

static TSTree *parse_with_ranges(
  TSParser *parser,
  AnvilTSSnapshot *snapshot,
  const TSRange *ranges,
  uint32_t range_count,
  ParseRun *run
) {
  if (!ts_parser_set_included_ranges(parser, ranges, range_count)) return NULL;
  TSParseOptions options = {
    .payload = run,
    .progress_callback = parse_progress,
  };
  return ts_parser_parse_with_options(parser, NULL, anvil_ts_snapshot_input(snapshot), options);
}

static bool is_inline_region(TSNode node) {
  const char *type = ts_node_type(node);
  return strcmp(type, "inline") == 0 || strcmp(type, "pipe_table_cell") == 0;
}

static bool append_inline_tree(
  AnvilMarkdownTree *result,
  TSTree *tree,
  TSRange source_range
) {
  if (result->inline_count == result->inline_capacity) {
    uint32_t next_capacity = result->inline_capacity ? result->inline_capacity * 2 : 32;
    AnvilMarkdownInlineTree *next = (AnvilMarkdownInlineTree *) realloc(
      result->inline_trees,
      sizeof(*next) * next_capacity
    );
    if (!next) return false;
    result->inline_trees = next;
    result->inline_capacity = next_capacity;
  }
  result->inline_trees[result->inline_count++] = (AnvilMarkdownInlineTree) {
    .tree = tree,
    .source_range = source_range,
  };
  return true;
}

static bool range_nonempty(TSRange range) {
  return range.end_byte > range.start_byte;
}

static bool append_range(TSRange **ranges, uint32_t *count, uint32_t *capacity, TSRange range) {
  if (!range_nonempty(range)) return true;
  if (*count == *capacity) {
    uint32_t next_capacity = *capacity ? *capacity * 2 : 8;
    TSRange *next = (TSRange *) realloc(*ranges, sizeof(*next) * next_capacity);
    if (!next) return false;
    *ranges = next;
    *capacity = next_capacity;
  }
  (*ranges)[(*count)++] = range;
  return true;
}

/* Match upstream's split-parser contract: parse each inline/cell region while
 * excluding named block children embedded after its first child. */
static bool build_region_ranges(TSNode node, TSRange **ranges, uint32_t *count) {
  *ranges = NULL;
  *count = 0;
  uint32_t capacity = 0;
  TSRange remainder = {
    .start_point = ts_node_start_point(node),
    .end_point = ts_node_end_point(node),
    .start_byte = ts_node_start_byte(node),
    .end_byte = ts_node_end_byte(node),
  };
  uint32_t child_count = ts_node_child_count(node);
  for (uint32_t i = 1; i < child_count; i++) {
    TSNode child = ts_node_child(node, i);
    if (!ts_node_is_named(child)) continue;
    uint32_t child_start = ts_node_start_byte(child);
    uint32_t child_end = ts_node_end_byte(child);
    if (child_start < remainder.start_byte || child_end > remainder.end_byte) continue;
    TSRange prefix = remainder;
    prefix.end_byte = child_start;
    prefix.end_point = ts_node_start_point(child);
    if (!append_range(ranges, count, &capacity, prefix)) goto fail;
    remainder.start_byte = child_end;
    remainder.start_point = ts_node_end_point(child);
  }
  if (!append_range(ranges, count, &capacity, remainder)) goto fail;
  return true;

fail:
  free(*ranges);
  *ranges = NULL;
  *count = 0;
  return false;
}

static bool parse_inline_regions(
  AnvilMarkdownTree *result,
  TSParser *inline_parser,
  TSNode node,
  ParseRun *run,
  char **error
) {
  if (is_inline_region(node)) {
    if (ts_node_end_byte(node) <= ts_node_start_byte(node)) return true;
    TSRange *ranges = NULL;
    uint32_t range_count = 0;
    if (!build_region_ranges(node, &ranges, &range_count)) {
      if (error) *error = parser_strdup("failed to build Markdown inline included ranges");
      return false;
    }
    if (range_count == 0) {
      free(ranges);
      return true;
    }
    TSTree *tree = parse_with_ranges(inline_parser, result->snapshot, ranges, range_count, run);
    TSRange source_range = {
      .start_point = ts_node_start_point(node),
      .end_point = ts_node_end_point(node),
      .start_byte = ts_node_start_byte(node),
      .end_byte = ts_node_end_byte(node),
    };
    free(ranges);
    if (!tree) {
      if (error) *error = parser_strdup(run->timed_out
        ? "Markdown inline parse timed out"
        : "Markdown inline parse failed");
      return false;
    }
    if (!append_inline_tree(result, tree, source_range)) {
      ts_tree_delete(tree);
      if (error) *error = parser_strdup("out of memory storing Markdown inline tree");
      return false;
    }
    return true;
  }

  uint32_t child_count = ts_node_child_count(node);
  for (uint32_t i = 0; i < child_count; i++) {
    if (!parse_inline_regions(result, inline_parser, ts_node_child(node, i), run, error)) return false;
  }
  return true;
}

AnvilMarkdownTree *anvil_markdown_tree_parse(
  AnvilTSSnapshot *snapshot,
  uint32_t timeout_ms,
  char **error
) {
  if (error) *error = NULL;
  if (!snapshot) {
    if (error) *error = parser_strdup("Markdown parse requires a source snapshot");
    return NULL;
  }
  const AnvilTSLanguage *block_language = anvil_ts_language_by_id("markdown");
  const AnvilTSLanguage *inline_language = anvil_ts_language_by_id("markdown_inline");
  if (!block_language || !inline_language ||
      !anvil_ts_language_is_compatible(block_language) ||
      !anvil_ts_language_is_compatible(inline_language)) {
    if (error) *error = parser_strdup("Markdown Tree-sitter grammars are unavailable or incompatible");
    return NULL;
  }

  AnvilMarkdownTree *result = (AnvilMarkdownTree *) calloc(1, sizeof(*result));
  TSParser *block_parser = ts_parser_new();
  TSParser *inline_parser = ts_parser_new();
  if (!result || !block_parser || !inline_parser) {
    free(result);
    if (block_parser) ts_parser_delete(block_parser);
    if (inline_parser) ts_parser_delete(inline_parser);
    if (error) *error = parser_strdup("out of memory creating Markdown parsers");
    return NULL;
  }
  result->snapshot = snapshot;
  anvil_ts_snapshot_retain(snapshot);

  bool languages_ok = ts_parser_set_language(block_parser, anvil_ts_language_ptr(block_language)) &&
    ts_parser_set_language(inline_parser, anvil_ts_language_ptr(inline_language));
  if (!languages_ok) {
    if (error) *error = parser_strdup("failed to configure Markdown Tree-sitter grammars");
    goto fail;
  }

  ParseRun run = {
    .started_ticks = SDL_GetTicks(),
    .timeout_ms = timeout_ms,
    .timed_out = false,
  };
  result->block_tree = parse_with_ranges(block_parser, snapshot, NULL, 0, &run);
  if (!result->block_tree) {
    if (error) *error = parser_strdup(run.timed_out
      ? "Markdown block parse timed out"
      : "Markdown block parse failed");
    goto fail;
  }
  if (!parse_inline_regions(result, inline_parser, ts_tree_root_node(result->block_tree), &run, error)) goto fail;

  ts_parser_delete(inline_parser);
  ts_parser_delete(block_parser);
  return result;

fail:
  ts_parser_delete(inline_parser);
  ts_parser_delete(block_parser);
  anvil_markdown_tree_free(result);
  return NULL;
}

void anvil_markdown_tree_free(AnvilMarkdownTree *tree) {
  if (!tree) return;
  for (uint32_t i = 0; i < tree->inline_count; i++) {
    if (tree->inline_trees[i].tree) ts_tree_delete(tree->inline_trees[i].tree);
  }
  free(tree->inline_trees);
  if (tree->block_tree) ts_tree_delete(tree->block_tree);
  if (tree->snapshot) anvil_ts_snapshot_free(tree->snapshot);
  free(tree);
}

const AnvilTSSnapshot *anvil_markdown_tree_snapshot(const AnvilMarkdownTree *tree) {
  return tree ? tree->snapshot : NULL;
}

TSTree *anvil_markdown_tree_block_tree(const AnvilMarkdownTree *tree) {
  return tree ? tree->block_tree : NULL;
}

uint32_t anvil_markdown_tree_inline_count(const AnvilMarkdownTree *tree) {
  return tree ? tree->inline_count : 0;
}

TSTree *anvil_markdown_tree_inline_tree(const AnvilMarkdownTree *tree, uint32_t index) {
  if (!tree || index >= tree->inline_count) return NULL;
  return tree->inline_trees[index].tree;
}

TSRange anvil_markdown_tree_inline_source_range(const AnvilMarkdownTree *tree, uint32_t index) {
  if (!tree || index >= tree->inline_count) return (TSRange) {0};
  return tree->inline_trees[index].source_range;
}
