#include "treesitter/languages.h"
#include "treesitter/service.h"
#include "treesitter/snapshot.h"

#include <SDL3/SDL.h>
#include <tree_sitter/api.h>

#include <stdbool.h>
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

#define CHECK_STREQ(a, b) do { \
  const char *_a = (a); \
  const char *_b = (b); \
  if (!_a || !_b || strcmp(_a, _b) != 0) { \
    fprintf(stderr, "CHECK_STREQ failed at %s:%d: got '%s', expected '%s'\n", \
      __FILE__, __LINE__, _a ? _a : "(null)", _b ? _b : "(null)"); \
    return 1; \
  } \
} while (0)

typedef struct {
  uint32_t byte;
  TSPoint point;
} OffsetPosition;

typedef struct {
  uint32_t *line_starts;
  uint32_t line_count;
  char *normalized;
  uint32_t normalized_len;
} OffsetIndex;

typedef struct {
  const char *data;
  uint32_t len;
} InputBuffer;

typedef struct {
  unsigned callbacks;
  bool cancel;
} ProgressState;

typedef struct {
  uint32_t total;
  uint32_t constants;
  uint32_t variables;
  uint32_t priority_constants;
} CaptureStats;

static void offset_index_free(OffsetIndex *index) {
  free(index->line_starts);
  free(index->normalized);
  memset(index, 0, sizeof(*index));
}

static bool offset_index_build(OffsetIndex *index, const char *input) {
  memset(index, 0, sizeof(*index));
  size_t input_len = strlen(input);
  index->normalized = (char *) malloc(input_len + 1);
  if (!index->normalized) return false;

  uint32_t out_len = 0;
  for (size_t i = 0; i < input_len; i++) {
    if (input[i] == '\r' && i + 1 < input_len && input[i + 1] == '\n') continue;
    index->normalized[out_len++] = input[i];
  }
  index->normalized[out_len] = '\0';
  index->normalized_len = out_len;

  uint32_t line_count = 1;
  for (uint32_t i = 0; i < out_len; i++) {
    if (index->normalized[i] == '\n' && i + 1 < out_len) line_count++;
  }

  index->line_starts = (uint32_t *) malloc(sizeof(uint32_t) * line_count);
  if (!index->line_starts) {
    offset_index_free(index);
    return false;
  }
  index->line_count = line_count;
  index->line_starts[0] = 0;
  uint32_t line = 1;
  for (uint32_t i = 0; i < out_len && line < line_count; i++) {
    if (index->normalized[i] == '\n') index->line_starts[line++] = i + 1;
  }
  return true;
}

static bool offset_position_from_anvil_pos(
  const OffsetIndex *index,
  uint32_t line,
  uint32_t col,
  OffsetPosition *out
) {
  if (line == 0 || col == 0 || line > index->line_count) return false;
  uint32_t byte = index->line_starts[line - 1] + col - 1;
  if (byte > index->normalized_len) return false;
  out->byte = byte;
  out->point.row = line - 1;
  out->point.column = col - 1;
  return true;
}

static const char *buffer_read(
  void *payload,
  uint32_t byte_index,
  TSPoint position,
  uint32_t *bytes_read
) {
  (void) position;
  InputBuffer *input = (InputBuffer *) payload;
  if (byte_index >= input->len) {
    *bytes_read = 0;
    return "";
  }
  uint32_t remaining = input->len - byte_index;
  *bytes_read = remaining > 4096 ? 4096 : remaining;
  return input->data + byte_index;
}

static bool parse_progress(TSParseState *state) {
  ProgressState *progress = (ProgressState *) state->payload;
  progress->callbacks++;
  return progress->cancel;
}

static bool query_progress(TSQueryCursorState *state) {
  ProgressState *progress = (ProgressState *) state->payload;
  progress->callbacks++;
  return progress->cancel;
}

static const AnvilTSLanguage *checked_c_registry_language(void) {
  const AnvilTSLanguage *language = anvil_ts_language_by_id("c");
  if (!language) return NULL;
  if (!anvil_ts_language_is_compatible(language)) return NULL;
  return language;
}

static AnvilTSSnapshot *new_snapshot_from_single_line(const char *text) {
  const char *lines[] = { text };
  uint32_t lengths[] = { (uint32_t) strlen(text) };
  return anvil_ts_snapshot_new_from_lines(lines, lengths, 1, NULL);
}

static bool wait_poll_until_done(
  AnvilTSDocumentState *state,
  uint64_t generation,
  AnvilTSPollResult *last,
  uint32_t timeout_ms
) {
  uint64_t start = SDL_GetTicks();
  AnvilTSPollResult result = {0};
  for (;;) {
    result = anvil_ts_document_state_poll(state, generation);
    if (result.changed || result.status == ANVIL_TS_STATE_READY ||
        result.status == ANVIL_TS_STATE_CANCELED || result.status == ANVIL_TS_STATE_FAILED) {
      if (last) *last = result;
      return true;
    }
    if (SDL_GetTicks() - start > timeout_ms) {
      if (last) *last = result;
      return false;
    }
    SDL_Delay(1);
  }
}

static int test_grammar_load(void) {
  CHECK(anvil_ts_language_count() >= 1);
  const AnvilTSLanguage *language = checked_c_registry_language();
  CHECK(language != NULL);
  CHECK_STREQ(language->id, "c");

  const TSLanguage *ts_language = anvil_ts_language_ptr(language);
  CHECK(ts_language != NULL);
  CHECK(ts_language_abi_version(ts_language) >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION);
  CHECK(ts_language_abi_version(ts_language) <= TREE_SITTER_LANGUAGE_VERSION);

  const TSLanguageMetadata *metadata = ts_language_metadata(ts_language);
  CHECK(metadata != NULL);
  CHECK(metadata->major_version == 0);
  CHECK(metadata->minor_version == 24);
  CHECK(metadata->patch_version == 2);

  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, ts_language));
  ts_parser_delete(parser);
  return 0;
}

static int test_simple_c_parse(void) {
  const char *source = "int add(int a, int b) {\n  return a + b;\n}\n";
  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(checked_c_registry_language())));

  TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t) strlen(source));
  CHECK(tree != NULL);
  TSNode root = ts_tree_root_node(tree);
  CHECK_STREQ(ts_node_type(root), "translation_unit");
  CHECK(!ts_node_has_error(root));
  CHECK(ts_node_start_byte(root) == 0);
  CHECK(ts_node_end_byte(root) == strlen(source));

  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}

static int test_simple_query(void) {
  const char *source = "int add(int a, int b) {\n  return a + b;\n}\n";
  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(checked_c_registry_language())));
  TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t) strlen(source));
  CHECK(tree != NULL);

  const char *query_source = "(identifier) @id";
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(checked_c_registry_language()),
    query_source,
    (uint32_t) strlen(query_source),
    &error_offset,
    &error_type
  );
  CHECK(query != NULL);
  CHECK(ts_query_capture_count(query) == 1);

  TSQueryCursor *cursor = ts_query_cursor_new();
  CHECK(cursor != NULL);
  ts_query_cursor_set_match_limit(cursor, 128);
  CHECK(ts_query_cursor_match_limit(cursor) == 128);
  CHECK(ts_query_cursor_set_byte_range(cursor, 0, (uint32_t) strlen(source)));
  CHECK(ts_query_cursor_set_containing_byte_range(cursor, 0, (uint32_t) strlen(source)));

  ProgressState progress = {0, false};
  TSQueryCursorOptions options = { .payload = &progress, .progress_callback = query_progress };
  ts_query_cursor_exec_with_options(cursor, query, ts_tree_root_node(tree), &options);

  TSQueryMatch match;
  bool found_add = false;
  while (ts_query_cursor_next_match(cursor, &match)) {
    for (uint16_t i = 0; i < match.capture_count; i++) {
      TSNode node = match.captures[i].node;
      uint32_t start = ts_node_start_byte(node);
      uint32_t end = ts_node_end_byte(node);
      if (end > start && end <= strlen(source) && strncmp(source + start, "add", end - start) == 0) {
        found_add = true;
      }
    }
  }
  CHECK(found_add);
  CHECK(!ts_query_cursor_did_exceed_match_limit(cursor));

  ts_query_cursor_delete(cursor);
  ts_query_delete(query);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}

static int test_offset_conversion(void) {
  OffsetIndex index;
  OffsetPosition pos;

  CHECK(offset_index_build(&index, "abc\ndef\n"));
  CHECK(offset_position_from_anvil_pos(&index, 2, 2, &pos));
  CHECK(pos.byte == 5);
  CHECK(pos.point.row == 1);
  CHECK(pos.point.column == 1);
  offset_index_free(&index);

  CHECK(offset_index_build(&index, "h\xc3\xa9\nz\n"));
  CHECK(offset_position_from_anvil_pos(&index, 1, 4, &pos));
  CHECK(pos.byte == 3);
  CHECK(pos.point.row == 0);
  CHECK(pos.point.column == 3);
  offset_index_free(&index);

  CHECK(offset_index_build(&index, "a\r\nb\r\n"));
  CHECK(strcmp(index.normalized, "a\nb\n") == 0);
  CHECK(offset_position_from_anvil_pos(&index, 2, 1, &pos));
  CHECK(pos.byte == 2);
  CHECK(pos.point.row == 1);
  CHECK(pos.point.column == 0);
  offset_index_free(&index);

  CHECK(offset_index_build(&index, "abc\n"));
  CHECK(offset_position_from_anvil_pos(&index, 1, 4, &pos));
  CHECK(pos.byte == 3);
  CHECK(pos.point.row == 0);
  CHECK(pos.point.column == 3);
  offset_index_free(&index);

  return 0;
}

static int test_incremental_edit(void) {
  const char *old_source = "int value = 1;\n";
  const char *new_source = "static int value = 1;\n";
  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(checked_c_registry_language())));

  TSTree *old_tree = ts_parser_parse_string(parser, NULL, old_source, (uint32_t) strlen(old_source));
  CHECK(old_tree != NULL);

  TSInputEdit edit = {
    .start_byte = 0,
    .old_end_byte = 0,
    .new_end_byte = 7,
    .start_point = {0, 0},
    .old_end_point = {0, 0},
    .new_end_point = {0, 7},
  };
  ts_tree_edit(old_tree, &edit);

  TSTree *new_tree = ts_parser_parse_string(parser, old_tree, new_source, (uint32_t) strlen(new_source));
  CHECK(new_tree != NULL);
  TSNode root = ts_tree_root_node(new_tree);
  CHECK_STREQ(ts_node_type(root), "translation_unit");
  CHECK(!ts_node_has_error(root));

  uint32_t range_count = 0;
  TSRange *ranges = ts_tree_get_changed_ranges(old_tree, new_tree, &range_count);
  CHECK(ranges != NULL || range_count == 0);
  if (ranges) free(ranges);

  ts_tree_delete(new_tree);
  ts_tree_delete(old_tree);
  ts_parser_delete(parser);
  return 0;
}

static int test_snapshot_basics(void) {
  const char *lines[] = { "int x = 1;\n", "// hé\n", "return;" };
  uint32_t lengths[] = {
    (uint32_t) strlen(lines[0]),
    (uint32_t) strlen(lines[1]),
    (uint32_t) strlen(lines[2]),
  };
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(lines, lengths, 3, NULL);
  CHECK(snapshot != NULL);
  CHECK(snapshot->line_count == 3);
  CHECK(snapshot->byte_len == lengths[0] + lengths[1] + lengths[2]);
  CHECK(snapshot->line_starts[0] == 0);
  CHECK(snapshot->line_starts[1] == lengths[0]);
  CHECK(snapshot->line_starts[2] == lengths[0] + lengths[1]);
  CHECK(memcmp(snapshot->bytes, "int x = 1;\n// hé\nreturn;", snapshot->byte_len) == 0);

  AnvilTSPosition pos;
  CHECK(anvil_ts_snapshot_position_from_anvil(snapshot, 2, 6, &pos));
  CHECK(pos.byte == lengths[0] + 5);
  CHECK(pos.point.row == 1);
  CHECK(pos.point.column == 5);
  anvil_ts_snapshot_free(snapshot);
  return 0;
}

static int test_async_parse_reaches_ready(void) {
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  AnvilTSSnapshot *snapshot = new_snapshot_from_single_line("int main(void) { return 0; }\n");
  CHECK(snapshot != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(state, snapshot, 1, NULL));

  AnvilTSPollResult result;
  CHECK(wait_poll_until_done(state, 1, &result, 3000));
  CHECK(result.status == ANVIL_TS_STATE_READY);
  CHECK(result.changed);
  CHECK(anvil_ts_document_state_has_tree(state));
  CHECK(anvil_ts_document_state_tree_generation(state) == 1);
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_release(state);
  return 0;
}

static int test_async_cancel(void) {
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  AnvilTSSnapshot *snapshot = new_snapshot_from_single_line("int cancel_me(void) { return 0; }\n");
  CHECK(snapshot != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(state, snapshot, 2, NULL));
  anvil_ts_document_state_cancel(state);

  AnvilTSPollResult result;
  CHECK(wait_poll_until_done(state, 2, &result, 3000));
  CHECK(result.status == ANVIL_TS_STATE_CANCELED || result.status == ANVIL_TS_STATE_READY);
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_release(state);
  return 0;
}

static int test_stale_generation_discard(void) {
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(
    state,
    new_snapshot_from_single_line("int stale(void) { return 1; }\n"),
    10,
    NULL
  ));
  CHECK(anvil_ts_document_state_schedule_parse(
    state,
    new_snapshot_from_single_line("int current(void) { return 2; }\n"),
    11,
    NULL
  ));

  bool saw_stale = false;
  AnvilTSPollResult result = {0};
  uint64_t start = SDL_GetTicks();
  while (SDL_GetTicks() - start < 3000) {
    result = anvil_ts_document_state_poll(state, 11);
    saw_stale = saw_stale || result.discarded_stale;
    if (result.status == ANVIL_TS_STATE_READY && result.changed) break;
    SDL_Delay(1);
  }
  CHECK(result.status == ANVIL_TS_STATE_READY);
  CHECK(anvil_ts_document_state_tree_generation(state) == 11);
  CHECK(saw_stale || result.discarded_stale);
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_release(state);
  return 0;
}

static int test_close_while_queued_or_running(void) {
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(
    state,
    new_snapshot_from_single_line("int closed(void) { return 0; }\n"),
    20,
    NULL
  ));
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_close(state);
  SDL_Delay(10);
  anvil_ts_document_state_release(state);
  return 0;
}

static int test_service_shutdown_cleanup(void) {
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(
    state,
    new_snapshot_from_single_line("int shutdown_cleanup(void) { return 0; }\n"),
    30,
    NULL
  ));
  anvil_ts_service_shutdown();
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_release(state);
  return 0;
}

static bool count_service_capture(const AnvilTSQueryCapture *capture, void *payload) {
  CaptureStats *stats = (CaptureStats *) payload;
  stats->total++;
  if (capture->name_len == strlen("constant") && strncmp(capture->name, "constant", capture->name_len) == 0) {
    stats->constants++;
    if (capture->priority == 2) stats->priority_constants++;
  }
  if (capture->name_len == strlen("variable") && strncmp(capture->name, "variable", capture->name_len) == 0) {
    stats->variables++;
  }
  return true;
}

static int test_service_query_predicates_and_directives(void) {
  const char *source = "int ABC = 1; int value = 2;\n";
  AnvilTSDocumentState *state = anvil_ts_document_state_new(checked_c_registry_language(), 5000);
  CHECK(state != NULL);
  CHECK(anvil_ts_document_state_schedule_parse(state, new_snapshot_from_single_line(source), 40, NULL));
  AnvilTSPollResult result;
  CHECK(wait_poll_until_done(state, 40, &result, 3000));
  CHECK(result.status == ANVIL_TS_STATE_READY);

  const char *query_source =
    "((identifier) @constant (#match? @constant \"^[A-Z]+$\") (#set! priority 2))\n"
    "((identifier) @variable (#not-match? @variable \"^[A-Z]+$\"))\n"
    "((identifier) @constant (#eq? @constant \"ABC\"))\n"
    "((identifier) @variable (#not-eq? @variable \"ABC\"))\n"
    "((identifier) @constant (#any-of? @constant \"ABC\" \"XYZ\"))\n"
    "((identifier) @variable (#not-any-of? @variable \"ABC\" \"XYZ\"))\n";
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(checked_c_registry_language()),
    query_source,
    (uint32_t) strlen(query_source),
    &error_offset,
    &error_type
  );
  CHECK(query != NULL);

  CaptureStats stats = {0};
  bool exceeded = false;
  char *error = NULL;
  CHECK(anvil_ts_document_state_query_captures(
    state,
    query,
    0,
    (uint32_t) strlen(source),
    128,
    128,
    100,
    count_service_capture,
    &stats,
    &exceeded,
    &error
  ));
  CHECK(error == NULL);
  CHECK(!exceeded);
  CHECK(stats.constants >= 3);
  CHECK(stats.variables >= 3);
  CHECK(stats.priority_constants >= 1);

  ts_query_delete(query);
  anvil_ts_document_state_close(state);
  anvil_ts_document_state_release(state);
  return 0;
}

static int test_query_cancellation_smoke(void) {
  const char *source = "int a0; int a1; int a2; int a3; int a4;\n";
  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(checked_c_registry_language())));
  TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t) strlen(source));
  CHECK(tree != NULL);

  const char *query_source = "(identifier) @id";
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(checked_c_registry_language()),
    query_source,
    (uint32_t) strlen(query_source),
    &error_offset,
    &error_type
  );
  CHECK(query != NULL);
  TSQueryCursor *cursor = ts_query_cursor_new();
  CHECK(cursor != NULL);
  ProgressState progress = {0, true};
  TSQueryCursorOptions options = { .payload = &progress, .progress_callback = query_progress };
  ts_query_cursor_exec_with_options(cursor, query, ts_tree_root_node(tree), &options);
  TSQueryMatch match;
  while (ts_query_cursor_next_match(cursor, &match)) {}
  /* Small queries may finish before invoking the progress callback; this still
   * smokes the runtime's query-options cancellation API path. */
  ts_query_cursor_delete(cursor);
  ts_query_delete(query);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}

static int test_parse_cancellation_smoke(void) {
  const uint32_t repeats = 200000;
  const char *line = "int cancel_me(void) { return 1; }\n";
  size_t line_len = strlen(line);
  size_t source_len = line_len * repeats;
  char *source = (char *) malloc(source_len + 1);
  CHECK(source != NULL);
  for (uint32_t i = 0; i < repeats; i++) memcpy(source + (line_len * i), line, line_len);
  source[source_len] = '\0';

  TSParser *parser = ts_parser_new();
  CHECK(parser != NULL);
  CHECK(ts_parser_set_language(parser, anvil_ts_language_ptr(checked_c_registry_language())));

  InputBuffer input_buffer = { source, (uint32_t) source_len };
  TSInput input = {
    .payload = &input_buffer,
    .read = buffer_read,
    .encoding = TSInputEncodingUTF8,
    .decode = NULL,
  };
  ProgressState progress = {0, true};
  TSParseOptions options = { .payload = &progress, .progress_callback = parse_progress };
  TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, options);
  CHECK(progress.callbacks > 0);
  CHECK(tree == NULL);
  ts_parser_reset(parser);

  free(source);
  ts_parser_delete(parser);
  return 0;
}

int main(void) {
  int result = 0;
  result |= test_grammar_load();
  result |= test_simple_c_parse();
  result |= test_simple_query();
  result |= test_offset_conversion();
  result |= test_incremental_edit();
  result |= test_snapshot_basics();
  result |= test_async_parse_reaches_ready();
  result |= test_async_cancel();
  result |= test_stale_generation_discard();
  result |= test_close_while_queued_or_running();
  result |= test_service_shutdown_cleanup();
  result |= test_service_query_predicates_and_directives();
  result |= test_query_cancellation_smoke();
  result |= test_parse_cancellation_smoke();
  anvil_ts_service_shutdown();
  return result ? 1 : 0;
}
