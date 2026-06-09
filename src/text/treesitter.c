#include "text/treesitter.h"
#include "thread_pool.h"

#include <tree_sitter/api.h>
#include <tree_sitter/tree-sitter-c.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern const TSLanguage *tree_sitter_c(void);

struct NativeTreeSitter {
  TSParser *parser;
  TSTree *tree;
  TSQuery *highlight_query;
  const TSLanguage *language;
  char *language_name;
  bool dirty;
  bool incremental_tree_valid;
  uint64_t parse_generation;
  AnvilTask *parse_task;
};

typedef struct AsyncParsePayload {
  char *source;
  size_t source_len;
  TSTree *old_tree;
  const TSLanguage *language;
  uint64_t generation;
} AsyncParsePayload;

typedef struct AsyncParseResult {
  TSTree *tree;
  uint64_t generation;
} AsyncParseResult;

typedef struct ParseInput {
  Buffer *buffer;
  char *scratch;
  size_t scratch_len;
} ParseInput;

static const char c_highlight_query[] =
  "\"break\" @keyword\n"
  "\"case\" @keyword\n"
  "\"const\" @keyword\n"
  "\"continue\" @keyword\n"
  "\"default\" @keyword\n"
  "\"do\" @keyword\n"
  "\"else\" @keyword\n"
  "\"enum\" @keyword\n"
  "\"extern\" @keyword\n"
  "\"for\" @keyword\n"
  "\"if\" @keyword\n"
  "\"inline\" @keyword\n"
  "\"return\" @keyword\n"
  "\"sizeof\" @keyword\n"
  "\"static\" @keyword\n"
  "\"struct\" @keyword\n"
  "\"switch\" @keyword\n"
  "\"typedef\" @keyword\n"
  "\"union\" @keyword\n"
  "\"volatile\" @keyword\n"
  "\"while\" @keyword\n"
  "\"#define\" @keyword\n"
  "\"#elif\" @keyword\n"
  "\"#else\" @keyword\n"
  "\"#endif\" @keyword\n"
  "\"#if\" @keyword\n"
  "\"#ifdef\" @keyword\n"
  "\"#ifndef\" @keyword\n"
  "\"#include\" @keyword\n"
  "(preproc_directive) @keyword\n"
  "(comment) @comment\n"
  "(string_literal) @string\n"
  "(system_lib_string) @string\n"
  "(number_literal) @number\n"
  "(char_literal) @number\n"
  "(primitive_type) @type\n"
  "(sized_type_specifier) @type\n"
  "(type_identifier) @type\n"
  "(field_identifier) @property\n"
  "(statement_identifier) @label\n"
  "(call_expression function: (identifier) @function)\n"
  "(call_expression function: (field_expression field: (field_identifier) @function))\n"
  "(function_declarator declarator: (identifier) @function)\n"
  "(preproc_function_def name: (identifier) @function)\n"
  "(identifier) @variable\n";

static char *ts_strdup_len(const char *text, size_t len) {
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  if (len > 0) memcpy(copy, text, len);
  copy[len] = '\0';
  return copy;
}

static char *ts_strdup(const char *text) {
  return text ? ts_strdup_len(text, strlen(text)) : NULL;
}

static void free_async_parse_payload(void *ptr) {
  AsyncParsePayload *payload = (AsyncParsePayload *) ptr;
  if (!payload) return;
  free(payload->source);
  if (payload->old_tree) ts_tree_delete(payload->old_tree);
  free(payload);
}

static void free_async_parse_result(void *ptr) {
  AsyncParseResult *result = (AsyncParseResult *) ptr;
  if (!result) return;
  if (result->tree) ts_tree_delete(result->tree);
  free(result);
}

static void *async_parse_task(void *ptr, SDL_AtomicInt *cancelled) {
  AsyncParsePayload *payload = (AsyncParsePayload *) ptr;
  if (!payload || !payload->language || SDL_GetAtomicInt(cancelled)) return NULL;

  TSParser *parser = ts_parser_new();
  if (!parser) return NULL;
  if (!ts_parser_set_language(parser, payload->language)) {
    ts_parser_delete(parser);
    return NULL;
  }

  TSTree *tree = NULL;
  if (!SDL_GetAtomicInt(cancelled)) {
    tree = ts_parser_parse_string(parser, payload->old_tree, payload->source, (uint32_t) payload->source_len);
  }
  ts_parser_delete(parser);
  if (!tree || SDL_GetAtomicInt(cancelled)) {
    if (tree) ts_tree_delete(tree);
    return NULL;
  }

  AsyncParseResult *result = (AsyncParseResult *) calloc(1, sizeof(AsyncParseResult));
  if (!result) {
    ts_tree_delete(tree);
    return NULL;
  }
  result->tree = tree;
  result->generation = payload->generation;
  return result;
}

static void cancel_parse_task(NativeTreeSitter *state) {
  if (!state || !state->parse_task) return;
  anvil_task_release(state->parse_task);
  state->parse_task = NULL;
}

static const char *read_from_buffer(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read) {
  (void) position;
  ParseInput *input = (ParseInput *) payload;
  if (!input || !input->buffer || !bytes_read) return NULL;

  free(input->scratch);
  input->scratch = NULL;
  input->scratch_len = 0;

  size_t len = buffer_len(input->buffer);
  if ((size_t) byte_index >= len) {
    *bytes_read = 0;
    return "";
  }

  size_t end = (size_t) byte_index + 4096;
  if (end > len) end = len;
  input->scratch = buffer_range_to_string(input->buffer, byte_index, end, &input->scratch_len);
  if (!input->scratch) {
    *bytes_read = 0;
    return "";
  }
  *bytes_read = (uint32_t) input->scratch_len;
  return input->scratch;
}

static bool parse_buffer(NativeTreeSitter *state, Buffer *buffer, TSTree *old_tree) {
  if (!state || !state->parser || !buffer) return false;
  ParseInput payload;
  memset(&payload, 0, sizeof(payload));
  payload.buffer = buffer;

  TSInput input;
  memset(&input, 0, sizeof(input));
  input.payload = &payload;
  input.read = read_from_buffer;
  input.encoding = TSInputEncodingUTF8;

  TSTree *new_tree = ts_parser_parse(state->parser, old_tree, input);
  free(payload.scratch);
  if (!new_tree) return false;
  if (state->tree) ts_tree_delete(state->tree);
  state->tree = new_tree;
  state->dirty = false;
  state->incremental_tree_valid = true;
  return true;
}

static bool language_for_name(const char *name, const TSLanguage **language_out, const char **query_out) {
  if (!name || strcmp(name, "c") != 0) return false;
  if (language_out) *language_out = tree_sitter_c();
  if (query_out) *query_out = c_highlight_query;
  return true;
}

NativeTreeSitter *native_treesitter_new(Buffer *buffer, const char *language_name) {
  NativeTreeSitter *state = (NativeTreeSitter *) calloc(1, sizeof(NativeTreeSitter));
  if (!state) return NULL;
  state->parser = ts_parser_new();
  if (!state->parser) {
    native_treesitter_free(state);
    return NULL;
  }
  if (!native_treesitter_set_language(state, buffer, language_name)) {
    native_treesitter_free(state);
    return NULL;
  }
  return state;
}

void native_treesitter_free(NativeTreeSitter *state) {
  if (!state) return;
  cancel_parse_task(state);
  if (state->highlight_query) ts_query_delete(state->highlight_query);
  if (state->tree) ts_tree_delete(state->tree);
  if (state->parser) ts_parser_delete(state->parser);
  free(state->language_name);
  free(state);
}

bool native_treesitter_set_language(NativeTreeSitter *state, Buffer *buffer, const char *language_name) {
  if (!state || !buffer) return false;
  cancel_parse_task(state);
  const TSLanguage *language = NULL;
  const char *query_source = NULL;
  if (!language_for_name(language_name, &language, &query_source)) return false;

  if (!ts_parser_set_language(state->parser, language)) return false;

  TSQueryError error_type = TSQueryErrorNone;
  uint32_t error_offset = 0;
  TSQuery *query = ts_query_new(language, query_source, (uint32_t) strlen(query_source), &error_offset, &error_type);
  if (!query) return false;

  char *name_copy = ts_strdup(language_name);
  if (!name_copy) {
    ts_query_delete(query);
    return false;
  }

  if (state->highlight_query) ts_query_delete(state->highlight_query);
  state->highlight_query = query;
  state->language = language;
  free(state->language_name);
  state->language_name = name_copy;
  state->incremental_tree_valid = false;
  state->parse_generation++;

  return native_treesitter_reparse(state, buffer);
}

const char *native_treesitter_language_name(const NativeTreeSitter *state) {
  return state ? state->language_name : NULL;
}

const char *native_treesitter_root_kind(const NativeTreeSitter *state) {
  if (!state || !state->tree) return NULL;
  TSNode root = ts_tree_root_node(state->tree);
  return ts_node_type(root);
}

bool native_treesitter_is_dirty(const NativeTreeSitter *state) {
  return state ? state->dirty : false;
}

bool native_treesitter_parse_pending(const NativeTreeSitter *state) {
  return state && state->parse_task;
}

bool native_treesitter_reparse(NativeTreeSitter *state, Buffer *buffer) {
  if (!state || !buffer) return false;
  cancel_parse_task(state);
  TSTree *old_tree = state->incremental_tree_valid ? state->tree : NULL;
  return parse_buffer(state, buffer, old_tree);
}

bool native_treesitter_schedule_reparse(NativeTreeSitter *state, Buffer *buffer) {
  if (!state || !buffer || !state->language || state->parse_task) return state && state->parse_task;

  size_t source_len = 0;
  char *source = buffer_to_string(buffer, &source_len);
  if (!source) return false;

  AsyncParsePayload *payload = (AsyncParsePayload *) calloc(1, sizeof(AsyncParsePayload));
  if (!payload) {
    free(source);
    return false;
  }
  payload->source = source;
  payload->source_len = source_len;
  payload->language = state->language;
  payload->generation = state->parse_generation;
  payload->old_tree = state->incremental_tree_valid && state->tree ? ts_tree_copy(state->tree) : NULL;

  state->parse_task = anvil_thread_pool_submit(
    anvil_system_thread_pool(),
    "tree-sitter-parse",
    async_parse_task,
    payload,
    free_async_parse_payload,
    free_async_parse_result
  );
  if (!state->parse_task) {
    free_async_parse_payload(payload);
    return false;
  }
  return true;
}

bool native_treesitter_poll_reparse(NativeTreeSitter *state) {
  if (!state || !state->parse_task) return false;
  AnvilTaskResult task_result = anvil_task_result_if_complete(state->parse_task);
  if (!task_result.complete) return false;
  state->parse_task = NULL;

  AsyncParseResult *result = (AsyncParseResult *) task_result.result;
  if (!result || !result->tree || task_result.being_cancelled || result->generation != state->parse_generation) {
    free_async_parse_result(result);
    return false;
  }

  if (state->tree) ts_tree_delete(state->tree);
  state->tree = result->tree;
  result->tree = NULL;
  state->dirty = false;
  state->incremental_tree_valid = true;
  free_async_parse_result(result);
  return true;
}

static TSPoint point_from_batch(BatchEditPoint point) {
  TSPoint out;
  out.row = (uint32_t) point.line;
  out.column = (uint32_t) point.col;
  return out;
}

bool native_treesitter_after_edit(NativeTreeSitter *state, Buffer *buffer, const BatchEditResult *result) {
  (void) buffer;
  if (!state || !result || !result->applied) return false;
  if (!result->edit_descriptor_count) return true;

  state->parse_generation++;

  if (state->tree && state->incremental_tree_valid && result->edit_descriptor_count == 1) {
    const BatchEditDescriptor *desc = &result->edit_descriptors[0];
    TSInputEdit edit;
    memset(&edit, 0, sizeof(edit));
    edit.start_byte = (uint32_t) desc->old_start_offset;
    edit.old_end_byte = (uint32_t) desc->old_end_offset;
    edit.new_end_byte = (uint32_t) desc->new_end_offset;
    edit.start_point = point_from_batch(desc->old_start_point);
    edit.old_end_point = point_from_batch(desc->old_end_point);
    edit.new_end_point = point_from_batch(desc->new_end_point);
    ts_tree_edit(state->tree, &edit);
    state->incremental_tree_valid = true;
  } else {
    state->incremental_tree_valid = false;
  }

  state->dirty = true;
  return true;
}

bool native_treesitter_after_snap(NativeTreeSitter *state, Buffer *buffer) {
  (void) buffer;
  if (!state) return false;
  state->dirty = true;
  state->incremental_tree_valid = false;
  state->parse_generation++;
  return true;
}

static bool append_highlight_span(
  NativeTreeSitterHighlightSpan **spans,
  size_t *count,
  size_t *capacity,
  size_t start,
  size_t end,
  const char *name,
  size_t name_len
) {
  if (start >= end || !name) return true;
  if (*count == *capacity) {
    size_t cap = *capacity ? *capacity * 2 : 32;
    NativeTreeSitterHighlightSpan *new_spans = (NativeTreeSitterHighlightSpan *) realloc(*spans, cap * sizeof(NativeTreeSitterHighlightSpan));
    if (!new_spans) return false;
    *spans = new_spans;
    *capacity = cap;
  }
  char *capture = ts_strdup_len(name, name_len);
  if (!capture) return false;
  (*spans)[*count].start_offset = start;
  (*spans)[*count].end_offset = end;
  (*spans)[*count].capture_name = capture;
  *count += 1;
  return true;
}

NativeTreeSitterHighlightSpan *native_treesitter_highlights(
  NativeTreeSitter *state,
  size_t start_offset,
  size_t end_offset,
  size_t *count_out
) {
  if (count_out) *count_out = 0;
  if (!state || !state->tree || !state->highlight_query || start_offset > end_offset) return NULL;

  TSQueryCursor *cursor = ts_query_cursor_new();
  if (!cursor) return NULL;

  TSNode root = ts_tree_root_node(state->tree);
  ts_query_cursor_exec(cursor, state->highlight_query, root);
  ts_query_cursor_set_byte_range(cursor, (uint32_t) start_offset, (uint32_t) end_offset);

  NativeTreeSitterHighlightSpan *spans = NULL;
  size_t count = 0;
  size_t capacity = 0;
  TSQueryMatch match;
  while (ts_query_cursor_next_match(cursor, &match)) {
    for (uint16_t i = 0; i < match.capture_count; ++i) {
      TSQueryCapture capture = match.captures[i];
      uint32_t capture_name_len = 0;
      const char *capture_name = ts_query_capture_name_for_id(state->highlight_query, capture.index, &capture_name_len);
      size_t start = ts_node_start_byte(capture.node);
      size_t end = ts_node_end_byte(capture.node);
      if (start < start_offset) start = start_offset;
      if (end > end_offset) end = end_offset;
      if (!append_highlight_span(&spans, &count, &capacity, start, end, capture_name, capture_name_len)) {
        native_treesitter_highlights_free(spans, count);
        ts_query_cursor_delete(cursor);
        return NULL;
      }
    }
  }

  ts_query_cursor_delete(cursor);
  if (count_out) *count_out = count;
  return spans;
}

void native_treesitter_highlights_free(NativeTreeSitterHighlightSpan *spans, size_t count) {
  if (!spans) return;
  for (size_t i = 0; i < count; ++i) free(spans[i].capture_name);
  free(spans);
}
