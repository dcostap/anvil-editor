#include "text/treesitter.h"
#include "thread_pool.h"

#include <SDL3/SDL.h>
#include <tree_sitter/api.h>
#include <tree_sitter/tree-sitter-c.h>

#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const TSLanguage *tree_sitter_c(void);

typedef const TSLanguage *(*NativeTreeSitterLanguageFn)(void);

typedef struct NativeTreeSitterCaptureStyle {
  const char *capture;
  const char *style;
  int priority;
} NativeTreeSitterCaptureStyle;

typedef struct NativeTreeSitterLanguageDef {
  const char *id;
  NativeTreeSitterLanguageFn language_fn;
  const char *highlight_query_asset;
  const char *const *extensions;
  size_t extension_count;
  const NativeTreeSitterCaptureStyle *capture_styles;
  size_t capture_style_count;
} NativeTreeSitterLanguageDef;

struct NativeTreeSitter {
  TSParser *parser;
  TSTree *tree;
  TSQuery *highlight_query;
  const TSLanguage *language;
  const NativeTreeSitterLanguageDef *language_def;
  char *language_name;
  bool dirty;
  bool incremental_tree_valid;
  uint64_t parse_generation;
  AnvilTask *parse_task;
};

typedef struct AsyncParsePayload {
  PieceTreeTextSnapshot snapshot;
  TSTree *old_tree;
  const TSLanguage *language;
  uint64_t generation;
} AsyncParsePayload;

typedef struct AsyncParseResult {
  TSTree *tree;
  uint64_t generation;
  bool cancelled;
} AsyncParseResult;

typedef struct ParseInput {
  Buffer *buffer;
  char *scratch;
  size_t scratch_len;
} ParseInput;

typedef struct SnapshotParseInput {
  const PieceTreeTextSnapshot *snapshot;
  char *scratch;
  size_t scratch_len;
} SnapshotParseInput;

typedef struct RawHighlightSpan {
  size_t start_offset;
  size_t end_offset;
  char *capture_name;
  const char *style_name;
  int priority;
} RawHighlightSpan;

typedef struct NativeTreeSitterQueryCacheEntry {
  const NativeTreeSitterLanguageDef *def;
  const TSLanguage *language;
  TSQuery *query;
  size_t refcount;
} NativeTreeSitterQueryCacheEntry;

static const char *const c_extensions[] = { "c", "h" };

static const NativeTreeSitterCaptureStyle c_capture_styles[] = {
  { "keyword", "keyword", 100 },
  { "string", "string", 90 },
  { "comment", "comment", 90 },
  { "number", "number", 80 },
  { "type", "type", 75 },
  { "function", "function", 70 },
  { "property", "property", 65 },
  { "label", "label", 60 },
  { "variable", "variable", 10 },
};

static const NativeTreeSitterLanguageDef language_defs[] = {
  {
    "c",
    tree_sitter_c,
    "c/highlights.scm",
    c_extensions,
    sizeof(c_extensions) / sizeof(c_extensions[0]),
    c_capture_styles,
    sizeof(c_capture_styles) / sizeof(c_capture_styles[0]),
  },
};

static NativeTreeSitterQueryCacheEntry query_cache[sizeof(language_defs) / sizeof(language_defs[0])];
static SDL_Mutex *query_cache_mutex = NULL;

static bool trace_enabled(void) {
  static int enabled = -1;
  if (enabled < 0) {
    const char *value = getenv("ANVIL_TREE_SITTER_LOG");
    enabled = value && value[0] && strcmp(value, "0") != 0 && strcmp(value, "false") != 0 ? 1 : 0;
  }
  return enabled != 0;
}

static void trace_log(const char *fmt, ...) {
  if (!trace_enabled()) return;
  va_list args;
  va_start(args, fmt);
  SDL_LogMessageV(SDL_LOG_CATEGORY_APPLICATION, SDL_LOG_PRIORITY_DEBUG, fmt, args);
  va_end(args);
}

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

static int ascii_casecmp(const char *a, const char *b) {
  if (!a || !b) return a == b ? 0 : (a ? 1 : -1);
  while (*a && *b) {
    int ca = tolower((unsigned char) *a++);
    int cb = tolower((unsigned char) *b++);
    if (ca != cb) return ca - cb;
  }
  return (unsigned char) *a - (unsigned char) *b;
}

static char *path_join2(const char *a, const char *b) {
  if (!a || !b) return NULL;
  size_t a_len = strlen(a);
  size_t b_len = strlen(b);
  bool needs_sep = a_len > 0 && a[a_len - 1] != '/' && a[a_len - 1] != '\\';
  char *path = (char *) malloc(a_len + (needs_sep ? 1 : 0) + b_len + 1);
  if (!path) return NULL;
  memcpy(path, a, a_len);
  size_t pos = a_len;
  if (needs_sep) path[pos++] = '/';
  memcpy(path + pos, b, b_len + 1);
  return path;
}

static char *read_file(const char *path, size_t *len_out) {
  if (len_out) *len_out = 0;
  FILE *file = fopen(path, "rb");
  if (!file) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  long file_len = ftell(file);
  if (file_len < 0) {
    fclose(file);
    return NULL;
  }
  if (fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  size_t len = (size_t) file_len;
  char *bytes = (char *) malloc(len + 1);
  if (!bytes) {
    fclose(file);
    return NULL;
  }
  if (len > 0 && fread(bytes, 1, len, file) != len) {
    free(bytes);
    fclose(file);
    return NULL;
  }
  fclose(file);
  bytes[len] = '\0';
  if (len_out) *len_out = len;
  return bytes;
}

static bool load_query_from_base(const char *base, const char *asset, char **text_out, size_t *len_out) {
  char *path = path_join2(base, asset);
  if (!path) return false;
  char *text = read_file(path, len_out);
  free(path);
  if (!text) return false;
  *text_out = text;
  return true;
}

static char *load_query_asset(const char *asset, size_t *len_out) {
  if (!asset) return NULL;

  char *text = NULL;
  const char *env_base = getenv("ANVIL_TREE_SITTER_QUERY_DIR");
  if (env_base && load_query_from_base(env_base, asset, &text, len_out)) return text;

  const char *base_path = SDL_GetBasePath();
  if (base_path) {
    char *query_base = path_join2(base_path, "data/treesitter/queries");
    if (query_base) {
      if (load_query_from_base(query_base, asset, &text, len_out)) {
        free(query_base);
        return text;
      }
      free(query_base);
    }
  }

#ifdef ANVIL_SOURCE_ROOT
  char *source_query_base = path_join2(ANVIL_SOURCE_ROOT, "data/treesitter/queries");
  if (source_query_base) {
    if (load_query_from_base(source_query_base, asset, &text, len_out)) {
      free(source_query_base);
      return text;
    }
    free(source_query_base);
  }
#endif

  if (load_query_from_base("data/treesitter/queries", asset, &text, len_out)) return text;
  return NULL;
}

static const NativeTreeSitterLanguageDef *language_def_for_name(const char *name) {
  if (!name) return NULL;
  for (size_t i = 0; i < sizeof(language_defs) / sizeof(language_defs[0]); ++i) {
    if (strcmp(language_defs[i].id, name) == 0) return &language_defs[i];
  }
  return NULL;
}

static bool query_cache_lock(void) {
  if (!query_cache_mutex) {
    query_cache_mutex = SDL_CreateMutex();
    if (!query_cache_mutex) return false;
  }
  SDL_LockMutex(query_cache_mutex);
  return true;
}

static NativeTreeSitterQueryCacheEntry *query_cache_entry_for_def(const NativeTreeSitterLanguageDef *def) {
  if (!def) return NULL;
  size_t index = (size_t) (def - language_defs);
  if (index >= sizeof(query_cache) / sizeof(query_cache[0])) return NULL;
  NativeTreeSitterQueryCacheEntry *entry = &query_cache[index];
  if (!entry->def) entry->def = def;
  return entry;
}

static TSQuery *query_cache_acquire(
  const NativeTreeSitterLanguageDef *def,
  const TSLanguage *language
) {
  if (!def || !language) return NULL;
  if (!query_cache_lock()) return NULL;
  NativeTreeSitterQueryCacheEntry *entry = query_cache_entry_for_def(def);
  if (!entry) {
    SDL_UnlockMutex(query_cache_mutex);
    return NULL;
  }

  if (!entry->query) {
    size_t query_len = 0;
    char *query_source = load_query_asset(def->highlight_query_asset, &query_len);
    if (!query_source) {
      trace_log("Tree-sitter query load failed language=%s asset=%s", def->id, def->highlight_query_asset ? def->highlight_query_asset : "");
      SDL_UnlockMutex(query_cache_mutex);
      return NULL;
    }

    TSQueryError error_type = TSQueryErrorNone;
    uint32_t error_offset = 0;
    entry->query = ts_query_new(language, query_source, (uint32_t) query_len, &error_offset, &error_type);
    free(query_source);
    if (!entry->query) {
      trace_log("Tree-sitter query compile failed language=%s offset=%u error=%d", def->id, error_offset, (int) error_type);
      SDL_UnlockMutex(query_cache_mutex);
      return NULL;
    }
    entry->language = language;
    trace_log("Tree-sitter query compiled language=%s", def->id);
  } else {
    trace_log("Tree-sitter query cache hit language=%s refs=%zu", def->id, entry->refcount);
  }

  entry->refcount++;
  TSQuery *query = entry->query;
  SDL_UnlockMutex(query_cache_mutex);
  return query;
}

static void query_cache_release(const NativeTreeSitterLanguageDef *def) {
  if (!def || !query_cache_mutex) return;
  SDL_LockMutex(query_cache_mutex);
  NativeTreeSitterQueryCacheEntry *entry = query_cache_entry_for_def(def);
  if (entry && entry->refcount > 0) entry->refcount--;
  SDL_UnlockMutex(query_cache_mutex);
}

void native_treesitter_shutdown_cache(void) {
  if (!query_cache_mutex) return;
  SDL_LockMutex(query_cache_mutex);
  for (size_t i = 0; i < sizeof(query_cache) / sizeof(query_cache[0]); ++i) {
    if (query_cache[i].query) ts_query_delete(query_cache[i].query);
    memset(&query_cache[i], 0, sizeof(query_cache[i]));
  }
  SDL_UnlockMutex(query_cache_mutex);
  SDL_DestroyMutex(query_cache_mutex);
  query_cache_mutex = NULL;
}

size_t native_treesitter_cached_query_count(void) {
  if (!query_cache_mutex) return 0;
  size_t count = 0;
  SDL_LockMutex(query_cache_mutex);
  for (size_t i = 0; i < sizeof(query_cache) / sizeof(query_cache[0]); ++i) {
    if (query_cache[i].query) count++;
  }
  SDL_UnlockMutex(query_cache_mutex);
  return count;
}

const char *native_treesitter_language_for_filename(const char *filename) {
  if (!filename) return NULL;
  const char *last_sep = strrchr(filename, '/');
  const char *last_backslash = strrchr(filename, '\\');
  if (!last_sep || (last_backslash && last_backslash > last_sep)) last_sep = last_backslash;
  const char *name = last_sep ? last_sep + 1 : filename;
  const char *dot = strrchr(name, '.');
  if (!dot || !dot[1]) return NULL;
  const char *ext = dot + 1;

  for (size_t i = 0; i < sizeof(language_defs) / sizeof(language_defs[0]); ++i) {
    const NativeTreeSitterLanguageDef *def = &language_defs[i];
    for (size_t j = 0; j < def->extension_count; ++j) {
      if (ascii_casecmp(ext, def->extensions[j]) == 0) return def->id;
    }
  }
  return NULL;
}

static void capture_style_for_name(
  const NativeTreeSitterLanguageDef *def,
  const char *capture,
  size_t capture_len,
  const char **style_out,
  int *priority_out
) {
  if (style_out) *style_out = NULL;
  if (priority_out) *priority_out = 0;
  if (!def || !capture) return;

  for (size_t i = 0; i < def->capture_style_count; ++i) {
    const NativeTreeSitterCaptureStyle *style = &def->capture_styles[i];
    if (strlen(style->capture) == capture_len && memcmp(style->capture, capture, capture_len) == 0) {
      if (style_out) *style_out = style->style;
      if (priority_out) *priority_out = style->priority;
      return;
    }
  }

  const char *dot = memchr(capture, '.', capture_len);
  if (dot) {
    size_t base_len = (size_t) (dot - capture);
    for (size_t i = 0; i < def->capture_style_count; ++i) {
      const NativeTreeSitterCaptureStyle *style = &def->capture_styles[i];
      if (strlen(style->capture) == base_len && memcmp(style->capture, capture, base_len) == 0) {
        if (style_out) *style_out = style->style;
        if (priority_out) *priority_out = style->priority;
        return;
      }
    }
  }

  if (style_out) *style_out = "normal";
}

static void free_async_parse_payload(void *ptr) {
  AsyncParsePayload *payload = (AsyncParsePayload *) ptr;
  if (!payload) return;
  piece_tree_text_snapshot_release(&payload->snapshot);
  if (payload->old_tree) ts_tree_delete(payload->old_tree);
  free(payload);
}

static void free_async_parse_result(void *ptr) {
  AsyncParseResult *result = (AsyncParseResult *) ptr;
  if (!result) return;
  if (result->tree) ts_tree_delete(result->tree);
  free(result);
}

static const char *read_from_snapshot(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read) {
  (void) position;
  SnapshotParseInput *input = (SnapshotParseInput *) payload;
  if (!input || !input->snapshot || !bytes_read) return NULL;

  free(input->scratch);
  input->scratch = NULL;
  input->scratch_len = 0;

  size_t len = piece_tree_text_snapshot_len(input->snapshot);
  if ((size_t) byte_index >= len) {
    *bytes_read = 0;
    return "";
  }

  size_t end = (size_t) byte_index + 4096;
  if (end > len) end = len;
  input->scratch = piece_tree_text_snapshot_range_to_string(input->snapshot, byte_index, end, &input->scratch_len);
  if (!input->scratch) {
    *bytes_read = 0;
    return "";
  }
  *bytes_read = (uint32_t) input->scratch_len;
  return input->scratch;
}

static bool parse_cancelled(TSParseState *state) {
  if (!state || !state->payload) return false;
  SDL_AtomicInt *cancelled = (SDL_AtomicInt *) state->payload;
  return SDL_GetAtomicInt(cancelled) != 0;
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

  SnapshotParseInput snapshot_input;
  memset(&snapshot_input, 0, sizeof(snapshot_input));
  snapshot_input.snapshot = &payload->snapshot;

  TSInput input;
  memset(&input, 0, sizeof(input));
  input.payload = &snapshot_input;
  input.read = read_from_snapshot;
  input.encoding = TSInputEncodingUTF8;

  TSParseOptions options;
  memset(&options, 0, sizeof(options));
  options.payload = cancelled;
  options.progress_callback = parse_cancelled;

  TSTree *tree = NULL;
  if (!SDL_GetAtomicInt(cancelled)) {
    tree = ts_parser_parse_with_options(parser, payload->old_tree, input, options);
  }
  free(snapshot_input.scratch);
  ts_parser_delete(parser);

  AsyncParseResult *result = (AsyncParseResult *) calloc(1, sizeof(AsyncParseResult));
  if (!result) {
    if (tree) ts_tree_delete(tree);
    return NULL;
  }
  result->tree = tree;
  result->generation = payload->generation;
  result->cancelled = SDL_GetAtomicInt(cancelled) != 0 || !tree;
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
  query_cache_release(state->language_def);
  state->highlight_query = NULL;
  if (state->tree) ts_tree_delete(state->tree);
  if (state->parser) ts_parser_delete(state->parser);
  free(state->language_name);
  free(state);
}

bool native_treesitter_set_language(NativeTreeSitter *state, Buffer *buffer, const char *language_name) {
  if (!state || !buffer) return false;
  cancel_parse_task(state);
  const NativeTreeSitterLanguageDef *def = language_def_for_name(language_name);
  if (!def) return false;
  const TSLanguage *language = def->language_fn ? def->language_fn() : NULL;
  if (!language) return false;

  if (!ts_parser_set_language(state->parser, language)) return false;

  TSQuery *query = query_cache_acquire(def, language);
  if (!query) return false;

  char *name_copy = ts_strdup(def->id);
  if (!name_copy) {
    query_cache_release(def);
    return false;
  }

  query_cache_release(state->language_def);
  state->highlight_query = query;
  state->language = language;
  state->language_def = def;
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

  AsyncParsePayload *payload = (AsyncParsePayload *) calloc(1, sizeof(AsyncParsePayload));
  if (!payload) return false;
  if (!piece_tree_text_snapshot_acquire(&buffer->tree, &payload->snapshot)) {
    free(payload);
    return false;
  }
  size_t snapshot_len = piece_tree_text_snapshot_len(&payload->snapshot);
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
    trace_log("Tree-sitter parse schedule failed language=%s generation=%llu bytes=%zu", state->language_name ? state->language_name : "", (unsigned long long) payload->generation, snapshot_len);
    free_async_parse_payload(payload);
    return false;
  }
  trace_log("Tree-sitter parse scheduled language=%s generation=%llu bytes=%zu incremental=%d", state->language_name ? state->language_name : "", (unsigned long long) payload->generation, snapshot_len, payload->old_tree != NULL);
  return true;
}

bool native_treesitter_poll_reparse(NativeTreeSitter *state) {
  if (!state || !state->parse_task) return false;
  AnvilTaskResult task_result = anvil_task_result_if_complete(state->parse_task);
  if (!task_result.complete) return false;
  state->parse_task = NULL;

  AsyncParseResult *result = (AsyncParseResult *) task_result.result;
  if (!result || !result->tree || result->cancelled || task_result.being_cancelled || result->generation != state->parse_generation) {
    trace_log(
      "Tree-sitter parse discarded language=%s result_generation=%llu current_generation=%llu cancelled=%d duration_ms=%llu",
      state->language_name ? state->language_name : "",
      result ? (unsigned long long) result->generation : 0ull,
      (unsigned long long) state->parse_generation,
      result ? (int) result->cancelled : (int) task_result.being_cancelled,
      (unsigned long long) task_result.duration_ms
    );
    free_async_parse_result(result);
    return false;
  }

  trace_log("Tree-sitter parse applied language=%s generation=%llu duration_ms=%llu", state->language_name ? state->language_name : "", (unsigned long long) result->generation, (unsigned long long) task_result.duration_ms);
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

static int compare_size_t(const void *a, const void *b) {
  size_t av = *(const size_t *) a;
  size_t bv = *(const size_t *) b;
  return av < bv ? -1 : av > bv ? 1 : 0;
}

static void raw_highlights_free(RawHighlightSpan *spans, size_t count) {
  if (!spans) return;
  for (size_t i = 0; i < count; ++i) free(spans[i].capture_name);
  free(spans);
}

static bool append_raw_highlight_span(
  RawHighlightSpan **spans,
  size_t *count,
  size_t *capacity,
  size_t start,
  size_t end,
  const char *name,
  size_t name_len,
  const char *style,
  int priority
) {
  if (start >= end || !name) return true;
  if (*count == *capacity) {
    size_t cap = *capacity ? *capacity * 2 : 32;
    RawHighlightSpan *new_spans = (RawHighlightSpan *) realloc(*spans, cap * sizeof(RawHighlightSpan));
    if (!new_spans) return false;
    *spans = new_spans;
    *capacity = cap;
  }
  char *capture = ts_strdup_len(name, name_len);
  if (!capture) return false;
  (*spans)[*count].start_offset = start;
  (*spans)[*count].end_offset = end;
  (*spans)[*count].capture_name = capture;
  (*spans)[*count].style_name = style ? style : "normal";
  (*spans)[*count].priority = priority;
  *count += 1;
  return true;
}

static bool append_boundary(size_t **boundaries, size_t *count, size_t *capacity, size_t value) {
  if (*count == *capacity) {
    size_t cap = *capacity ? *capacity * 2 : 64;
    size_t *new_boundaries = (size_t *) realloc(*boundaries, cap * sizeof(size_t));
    if (!new_boundaries) return false;
    *boundaries = new_boundaries;
    *capacity = cap;
  }
  (*boundaries)[(*count)++] = value;
  return true;
}

static bool append_highlight_span(
  NativeTreeSitterHighlightSpan **spans,
  size_t *count,
  size_t *capacity,
  size_t start,
  size_t end,
  const char *capture,
  const char *style,
  int priority
) {
  if (start >= end || !capture) return true;
  if (*count > 0) {
    NativeTreeSitterHighlightSpan *last = &(*spans)[*count - 1];
    if (last->end_offset == start && last->priority == priority &&
        strcmp(last->capture_name ? last->capture_name : "", capture) == 0 &&
        strcmp(last->style_name ? last->style_name : "", style ? style : "normal") == 0) {
      last->end_offset = end;
      return true;
    }
  }
  if (*count == *capacity) {
    size_t cap = *capacity ? *capacity * 2 : 32;
    NativeTreeSitterHighlightSpan *new_spans = (NativeTreeSitterHighlightSpan *) realloc(*spans, cap * sizeof(NativeTreeSitterHighlightSpan));
    if (!new_spans) return false;
    *spans = new_spans;
    *capacity = cap;
  }
  char *capture_copy = ts_strdup(capture);
  char *style_copy = ts_strdup(style ? style : "normal");
  if (!capture_copy || !style_copy) {
    free(capture_copy);
    free(style_copy);
    return false;
  }
  (*spans)[*count].start_offset = start;
  (*spans)[*count].end_offset = end;
  (*spans)[*count].capture_name = capture_copy;
  (*spans)[*count].style_name = style_copy;
  (*spans)[*count].priority = priority;
  *count += 1;
  return true;
}

static bool normalize_highlights(
  const RawHighlightSpan *raw,
  size_t raw_count,
  NativeTreeSitterHighlightSpan **spans_out,
  size_t *count_out
) {
  *spans_out = NULL;
  *count_out = 0;
  if (raw_count == 0) return true;

  size_t *boundaries = NULL;
  size_t boundary_count = 0;
  size_t boundary_capacity = 0;
  for (size_t i = 0; i < raw_count; ++i) {
    if (!append_boundary(&boundaries, &boundary_count, &boundary_capacity, raw[i].start_offset) ||
        !append_boundary(&boundaries, &boundary_count, &boundary_capacity, raw[i].end_offset)) {
      free(boundaries);
      return false;
    }
  }
  qsort(boundaries, boundary_count, sizeof(size_t), compare_size_t);

  NativeTreeSitterHighlightSpan *spans = NULL;
  size_t count = 0;
  size_t capacity = 0;
  for (size_t b = 1; b < boundary_count; ++b) {
    size_t start = boundaries[b - 1];
    size_t end = boundaries[b];
    if (start == end) continue;

    const RawHighlightSpan *best = NULL;
    for (size_t i = 0; i < raw_count; ++i) {
      if (raw[i].start_offset <= start && raw[i].end_offset >= end) {
        if (!best || raw[i].priority > best->priority ||
            (raw[i].priority == best->priority && raw[i].start_offset >= best->start_offset && raw[i].end_offset <= best->end_offset)) {
          best = &raw[i];
        }
      }
    }
    if (best) {
      if (!append_highlight_span(&spans, &count, &capacity, start, end, best->capture_name, best->style_name, best->priority)) {
        free(boundaries);
        native_treesitter_highlights_free(spans, count);
        return false;
      }
    }
  }

  free(boundaries);
  *spans_out = spans;
  *count_out = count;
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

  RawHighlightSpan *raw = NULL;
  size_t raw_count = 0;
  size_t raw_capacity = 0;
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
      const char *style_name = NULL;
      int priority = 0;
      capture_style_for_name(state->language_def, capture_name, capture_name_len, &style_name, &priority);
      if (!append_raw_highlight_span(&raw, &raw_count, &raw_capacity, start, end, capture_name, capture_name_len, style_name, priority)) {
        raw_highlights_free(raw, raw_count);
        ts_query_cursor_delete(cursor);
        return NULL;
      }
    }
  }

  ts_query_cursor_delete(cursor);

  NativeTreeSitterHighlightSpan *spans = NULL;
  size_t count = 0;
  if (!normalize_highlights(raw, raw_count, &spans, &count)) {
    raw_highlights_free(raw, raw_count);
    return NULL;
  }
  raw_highlights_free(raw, raw_count);
  if (count_out) *count_out = count;
  return spans;
}

void native_treesitter_highlights_free(NativeTreeSitterHighlightSpan *spans, size_t count) {
  if (!spans) return;
  for (size_t i = 0; i < count; ++i) {
    free(spans[i].capture_name);
    free(spans[i].style_name);
  }
  free(spans);
}
