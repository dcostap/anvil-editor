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
  bool incremental;
  uint32_t reused_inline_count;
  TSInputEdit input_edit;
};

typedef struct ParseRun {
  uint64_t started_ticks;
  uint32_t timeout_ms;
  AnvilMarkdownCancelCallback cancel_callback;
  void *cancel_payload;
  bool timed_out;
  bool cancelled;
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
  if (!run) return false;
  if (run->cancel_callback && run->cancel_callback(run->cancel_payload)) {
    run->cancelled = true;
    return true;
  }
  if (run->timeout_ms == 0 || SDL_GetTicks() - run->started_ticks < run->timeout_ms) return false;
  run->timed_out = true;
  return true;
}

static TSTree *parse_with_ranges(
  TSParser *parser,
  AnvilTSSnapshot *snapshot,
  const TSRange *ranges,
  uint32_t range_count,
  TSTree *old_tree,
  ParseRun *run
) {
  if (!ts_parser_set_included_ranges(parser, ranges, range_count)) return NULL;
  TSParseOptions options = {
    .payload = run,
    .progress_callback = parse_progress,
  };
  return ts_parser_parse_with_options(parser, old_tree, anvil_ts_snapshot_input(snapshot), options);
}

static TSPoint snapshot_point_for_byte(const AnvilTSSnapshot *snapshot, uint32_t byte) {
  if (!snapshot || snapshot->line_count == 0) return (TSPoint) {0};
  if (byte > snapshot->byte_len) byte = snapshot->byte_len;
  uint32_t low = 0;
  uint32_t high = snapshot->line_count;
  while (low + 1 < high) {
    uint32_t mid = low + (high - low) / 2;
    if (snapshot->line_starts[mid] <= byte) low = mid;
    else high = mid;
  }
  return (TSPoint) { .row = low, .column = byte - snapshot->line_starts[low] };
}

static bool utf8_continuation(unsigned char byte) {
  return (byte & 0xc0) == 0x80;
}

static TSInputEdit snapshot_aggregate_edit(
  const AnvilTSSnapshot *old_snapshot,
  const AnvilTSSnapshot *new_snapshot
) {
  uint32_t prefix = 0;
  uint32_t shared = old_snapshot->byte_len < new_snapshot->byte_len
    ? old_snapshot->byte_len : new_snapshot->byte_len;
  while (prefix < shared && old_snapshot->bytes[prefix] == new_snapshot->bytes[prefix]) prefix++;
  while (prefix > 0 && prefix < old_snapshot->byte_len &&
    utf8_continuation((unsigned char)old_snapshot->bytes[prefix])) prefix--;

  uint32_t old_end = old_snapshot->byte_len;
  uint32_t new_end = new_snapshot->byte_len;
  while (old_end > prefix && new_end > prefix &&
    old_snapshot->bytes[old_end - 1] == new_snapshot->bytes[new_end - 1]) {
    old_end--;
    new_end--;
  }
  while (old_end < old_snapshot->byte_len && new_end < new_snapshot->byte_len &&
    (utf8_continuation((unsigned char)old_snapshot->bytes[old_end]) ||
      utf8_continuation((unsigned char)new_snapshot->bytes[new_end]))) {
    old_end++;
    new_end++;
  }

  return (TSInputEdit) {
    .start_byte = prefix,
    .old_end_byte = old_end,
    .new_end_byte = new_end,
    .start_point = snapshot_point_for_byte(old_snapshot, prefix),
    .old_end_point = snapshot_point_for_byte(old_snapshot, old_end),
    .new_end_point = snapshot_point_for_byte(new_snapshot, new_end),
  };
}

static uint32_t map_old_start_byte(uint32_t byte, const TSInputEdit *edit) {
  if (byte < edit->start_byte ||
    (byte == edit->start_byte && edit->old_end_byte > edit->start_byte)) return byte;
  if (byte >= edit->old_end_byte) return edit->new_end_byte + (byte - edit->old_end_byte);
  return edit->new_end_byte;
}

static uint32_t map_old_end_byte(uint32_t byte, const TSInputEdit *edit) {
  if (byte <= edit->start_byte) return byte;
  if (byte >= edit->old_end_byte) return edit->new_end_byte + (byte - edit->old_end_byte);
  return edit->new_end_byte;
}

static bool mapped_range_matches(TSRange old_range, TSRange new_range, const TSInputEdit *edit) {
  return map_old_start_byte(old_range.start_byte, edit) == new_range.start_byte &&
    map_old_end_byte(old_range.end_byte, edit) == new_range.end_byte;
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
  const AnvilMarkdownTree *previous,
  const TSInputEdit *edit,
  uint32_t *previous_cursor,
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
    TSRange source_range = {
      .start_point = ts_node_start_point(node),
      .end_point = ts_node_end_point(node),
      .start_byte = ts_node_start_byte(node),
      .end_byte = ts_node_end_byte(node),
    };
    TSTree *old_tree = NULL;
    if (previous && edit) {
      uint32_t old_index = *previous_cursor;
      while (old_index < previous->inline_count) {
        TSRange old_range = previous->inline_trees[old_index].source_range;
        uint32_t mapped_start = map_old_start_byte(old_range.start_byte, edit);
        uint32_t mapped_end = map_old_end_byte(old_range.end_byte, edit);
        if (mapped_range_matches(old_range, source_range, edit)) {
          old_tree = ts_tree_copy(previous->inline_trees[old_index].tree);
          if (old_tree) ts_tree_edit(old_tree, edit);
          *previous_cursor = old_index + 1;
          break;
        }
        if (mapped_end <= source_range.start_byte) {
          old_index++;
          *previous_cursor = old_index;
          continue;
        }
        if (mapped_start >= source_range.end_byte) break;
        old_index++;
        *previous_cursor = old_index;
      }
    }
    TSTree *tree = parse_with_ranges(inline_parser, result->snapshot, ranges, range_count, old_tree, run);
    if (tree && old_tree) result->reused_inline_count++;
    if (old_tree) ts_tree_delete(old_tree);
    free(ranges);
    if (!tree) {
      if (error) *error = parser_strdup(run->cancelled
        ? "Markdown parse cancelled"
        : (run->timed_out ? "Markdown inline parse timed out" : "Markdown inline parse failed"));
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
    if (!parse_inline_regions(
      result, inline_parser, ts_node_child(node, i), previous, edit, previous_cursor, run, error
    )) return false;
  }
  return true;
}

static AnvilMarkdownTree *markdown_tree_parse_internal(
  AnvilTSSnapshot *snapshot,
  const AnvilMarkdownTree *previous,
  uint32_t timeout_ms,
  AnvilMarkdownCancelCallback cancel_callback,
  void *cancel_payload,
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
  result->incremental = previous && previous->snapshot && previous->block_tree;
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
    .cancel_callback = cancel_callback,
    .cancel_payload = cancel_payload,
    .timed_out = false,
    .cancelled = false,
  };
  TSInputEdit edit = {0};
  TSTree *old_block_tree = NULL;
  if (result->incremental) {
    edit = snapshot_aggregate_edit(previous->snapshot, snapshot);
    result->input_edit = edit;
    old_block_tree = ts_tree_copy(previous->block_tree);
    if (old_block_tree) ts_tree_edit(old_block_tree, &edit);
    else result->incremental = false;
  }
  result->block_tree = parse_with_ranges(block_parser, snapshot, NULL, 0, old_block_tree, &run);
  if (old_block_tree) ts_tree_delete(old_block_tree);
  if (!result->block_tree) {
    if (error) *error = parser_strdup(run.cancelled
      ? "Markdown parse cancelled"
      : (run.timed_out ? "Markdown block parse timed out" : "Markdown block parse failed"));
    goto fail;
  }
  uint32_t previous_cursor = 0;
  if (!parse_inline_regions(
    result,
    inline_parser,
    ts_tree_root_node(result->block_tree),
    result->incremental ? previous : NULL,
    result->incremental ? &edit : NULL,
    &previous_cursor,
    &run,
    error
  )) goto fail;

  ts_parser_delete(inline_parser);
  ts_parser_delete(block_parser);
  return result;

fail:
  ts_parser_delete(inline_parser);
  ts_parser_delete(block_parser);
  anvil_markdown_tree_free(result);
  return NULL;
}

AnvilMarkdownTree *anvil_markdown_tree_parse(
  AnvilTSSnapshot *snapshot,
  uint32_t timeout_ms,
  AnvilMarkdownCancelCallback cancel_callback,
  void *cancel_payload,
  char **error
) {
  return markdown_tree_parse_internal(
    snapshot, NULL, timeout_ms, cancel_callback, cancel_payload, error
  );
}

AnvilMarkdownTree *anvil_markdown_tree_parse_incremental(
  AnvilTSSnapshot *snapshot,
  const AnvilMarkdownTree *previous,
  uint32_t timeout_ms,
  AnvilMarkdownCancelCallback cancel_callback,
  void *cancel_payload,
  char **error
) {
  return markdown_tree_parse_internal(
    snapshot, previous, timeout_ms, cancel_callback, cancel_payload, error
  );
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

bool anvil_markdown_tree_was_incremental(const AnvilMarkdownTree *tree) {
  return tree && tree->incremental;
}

uint32_t anvil_markdown_tree_reused_inline_count(const AnvilMarkdownTree *tree) {
  return tree ? tree->reused_inline_count : 0;
}

bool anvil_markdown_tree_input_edit(const AnvilMarkdownTree *tree, TSInputEdit *edit) {
  if (!tree || !tree->incremental || !edit) return false;
  *edit = tree->input_edit;
  return true;
}
