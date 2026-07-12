#include "worker_pool.h"

#include "markdown_parser.h"
#include "markdown_extensions.h"
#include "treesitter/languages.h"
#include "treesitter/query_cache.h"
#include "treesitter/project_index.h"
#include "treesitter/service.h"
#include "treesitter/snapshot.h"

#include <tree_sitter/api.h>
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ANVIL_WORKER_STATUS_QUEUED 0
#define ANVIL_WORKER_STATUS_RUNNING 1
#define ANVIL_WORKER_STATUS_COMPLETE 2
#define ANVIL_WORKER_STATUS_CANCELLED 3
#define ANVIL_WORKER_STATUS_FAILED 4

struct AnvilWorkerJob {
  SDL_AtomicInt refcount;
  SDL_AtomicInt cancel;
  SDL_AtomicInt status;
  uint64_t id;
  char *kind;
  char *value;
  int count;
  uint32_t sleep_ms;

  char *path;
  char *relpath;
  char *language;
  char *text;
  size_t text_len;
  char *outline_query;
  size_t outline_query_len;
  char *usage_query;
  size_t usage_query_len;
  char *cancel_token;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;
  uint32_t max_file_bytes;
  uint32_t result_capabilities;
  AnvilWorkerTreeSitterIndexResult *previous_result;
  AnvilWorkerProjectBatchFileSpec *project_files;
  uint32_t project_file_count;
  uint64_t project_builder_id;
  AnvilTSProjectBuilder *project_builder;
  AnvilTSProjectSnapshot *project_base_snapshot;
  AnvilTSProjectSnapshot *project_snapshot_to_release;
  bool close_project_builder;
  uint32_t project_usage_cap;
  char *project_root;
  char **project_scan_paths;
  uint32_t project_scan_path_count;
  char **project_remove_paths;
  uint32_t project_remove_path_count;
  bool project_scoped;
  char **project_excluded_paths;
  uint32_t project_excluded_path_count;
  char **project_ignore_patterns;
  uint32_t project_ignore_pattern_count;
  AnvilWorkerProjectRunLanguageSpec *project_languages;
  uint32_t project_language_count;
  uint32_t project_progress_files;
  bool project_publish_partial_snapshots;
  struct AnvilWorkerJob *cancel_parent;

  struct AnvilWorkerJob *next;
  struct AnvilWorkerJob *running_next;
};

struct AnvilWorkerResult {
  uint64_t job_id;
  char *kind;
  char *type;
  char *value;
  char *error;
  int index;
  bool cancelled;
  uint32_t files_completed;
  uint32_t files_skipped;
  uint32_t files_reused;
  uint32_t symbols_found;
  uint32_t usages_found;
  double batch_total_ms;
  double batch_parse_ms;
  double batch_project_record_ms;
  double project_builder_ms;
  double project_snapshot_ms;
  AnvilWorkerTreeSitterIndexResult *treesitter_index_result;
  AnvilTSProjectSnapshot *project_snapshot;
  struct AnvilWorkerResult *next;
};

typedef struct AnvilWorkerTreeSitterCapture {
  char *name;
  uint32_t name_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  int32_t priority;
  uint32_t match_id;
  uint32_t pattern_index;
  uint32_t capture_index;
  uint32_t order;
  uint64_t node_id;
} AnvilWorkerTreeSitterCapture;

typedef struct AnvilWorkerTreeSitterQueryResult {
  AnvilWorkerTreeSitterCapture *captures;
  uint32_t count;
  uint32_t capacity;
  uint64_t query_ms;
  uint64_t query_ns;
  uint64_t query_compile_ns;
  uint64_t line_index_ns;
  uint64_t query_fingerprint;
  char *status;
  char *error;
  bool exceeded_match_limit;
  bool query_cache_hit;
  bool query_cache_miss;
  uint32_t *line_order;
  uint32_t *line_tree_max_end;
  bool line_index_ready;
} AnvilWorkerTreeSitterQueryResult;

struct AnvilWorkerTreeSitterIndexResult {
  SDL_AtomicInt refcount;
  char *language;
  char *outline_query_source;
  char *usage_query_source;
  uint32_t byte_len;
  uint32_t line_count;
  uint64_t parse_ms;
  uint64_t block_parse_ms;
  uint64_t inline_parse_ms;
  uint64_t total_ms;
  uint64_t total_ns;
  uint64_t prepare_input_ns;
  uint64_t parser_setup_ns;
  uint64_t parse_ns;
  uint64_t project_record_ns;
  uint32_t result_capabilities;
  uint32_t line_indexes_skipped;
  bool parser_reused;
  bool incremental;
  bool outline_query_reusable;
  uint32_t reused_block_capture_count;
  uint32_t reused_inline_count;
  AnvilMarkdownTree *markdown_tree;
  AnvilTSProjectFileResult *project_file;
  AnvilWorkerTreeSitterQueryResult outline;
  AnvilWorkerTreeSitterQueryResult usage;
};

struct AnvilWorkerCancelToken {
  SDL_AtomicInt refcount;
  SDL_AtomicInt cancelled;
  char *name;
  struct AnvilWorkerCancelToken *next;
};

static SDL_InitState cancel_tokens_init;
static SDL_Mutex *cancel_tokens_mutex = NULL;
static AnvilWorkerCancelToken *cancel_tokens = NULL;
static SDL_AtomicInt cancel_token_sequence;
static SDL_AtomicInt markdown_semantic_id_sequence;
static bool project_run_path_belongs(const char *path, const char *root);
static SDL_InitState project_parse_slots_init;
static SDL_Semaphore *project_parse_slots;

typedef struct AnvilWorkerContext {
  struct AnvilWorkerPool *pool;
  TSParser *parser;
  TSQueryCursor *query_cursor;
} AnvilWorkerContext;

struct AnvilWorkerPool {
  char *name;
  int worker_count;
  SDL_Thread **workers;
  AnvilWorkerContext *contexts;
  SDL_Mutex *queue_mutex;
  SDL_Condition *queue_cond;
  SDL_Mutex *result_mutex;
  AnvilWorkerJob *input_first;
  AnvilWorkerJob **input_last;
  AnvilWorkerJob *running_first;
  AnvilWorkerResult *result_first;
  AnvilWorkerResult **result_last;
  bool terminate;
  uint64_t next_job_id;
  uint64_t submitted;
  uint64_t completed;
  uint64_t cancelled;
  uint64_t failed;
  uint64_t result_count;
  uint32_t active_project_runs;
};

static char *pool_memdup0(const char *source, size_t len) {
  if (!source || len == SIZE_MAX) return NULL;
  char *copy = (char *)SDL_malloc(len + 1);
  if (!copy) return NULL;
  if (len) memcpy(copy, source, len);
  copy[len] = '\0';
  return copy;
}

static char *pool_strdup(const char *s) {
  return s ? pool_memdup0(s, strlen(s)) : NULL;
}

static char *pool_textdup(const char *source, size_t len) {
  if (!source || len == SIZE_MAX) return NULL;
  char *copy = (char *)malloc(len + 1);
  if (!copy) return NULL;
  if (len) memcpy(copy, source, len);
  copy[len] = '\0';
  return copy;
}

static void pool_set_error(char **error, const char *message) {
  if (!error) return;
  *error = pool_strdup(message ? message : "worker pool error");
}

static SDL_Mutex *cancel_token_mutex(void) {
  if (SDL_ShouldInit(&cancel_tokens_init)) {
    cancel_tokens_mutex = SDL_CreateMutex();
    SDL_SetInitialized(&cancel_tokens_init, cancel_tokens_mutex != NULL);
  }
  return cancel_tokens_mutex;
}

static char *unique_cancel_token_name(void) {
  int seq = SDL_AddAtomicInt(&cancel_token_sequence, 1) + 1;
  char buffer[128];
  snprintf(buffer, sizeof(buffer), "anvil-cancel-token-%llu-%d", (unsigned long long)SDL_GetTicksNS(), seq);
  return pool_strdup(buffer);
}

AnvilWorkerCancelToken *anvil_worker_cancel_token_create(const char *name) {
  AnvilWorkerCancelToken *token = (AnvilWorkerCancelToken *)SDL_calloc(1, sizeof(*token));
  if (!token) return NULL;
  SDL_SetAtomicInt(&token->refcount, 1);
  token->name = name && name[0] ? pool_strdup(name) : unique_cancel_token_name();
  if (!token->name) {
    SDL_free(token);
    return NULL;
  }
  SDL_Mutex *mutex = cancel_token_mutex();
  if (!mutex) {
    SDL_free(token->name);
    SDL_free(token);
    return NULL;
  }
  SDL_LockMutex(mutex);
  token->next = cancel_tokens;
  cancel_tokens = token;
  SDL_UnlockMutex(mutex);
  return token;
}

AnvilWorkerCancelToken *anvil_worker_cancel_token_open(const char *name) {
  if (!name || !name[0]) return NULL;
  SDL_Mutex *mutex = cancel_token_mutex();
  if (!mutex) return NULL;
  SDL_LockMutex(mutex);
  for (AnvilWorkerCancelToken *token = cancel_tokens; token; token = token->next) {
    if (token->name && strcmp(token->name, name) == 0) {
      SDL_AtomicIncRef(&token->refcount);
      SDL_UnlockMutex(mutex);
      return token;
    }
  }
  SDL_UnlockMutex(mutex);
  return NULL;
}

void anvil_worker_cancel_token_retain(AnvilWorkerCancelToken *token) {
  if (token) SDL_AtomicIncRef(&token->refcount);
}

void anvil_worker_cancel_token_release(AnvilWorkerCancelToken *token) {
  if (!token) return;
  SDL_Mutex *mutex = cancel_token_mutex();
  bool should_free = false;
  if (mutex) SDL_LockMutex(mutex);
  should_free = SDL_AtomicDecRef(&token->refcount);
  if (should_free) {
    AnvilWorkerCancelToken **cursor = &cancel_tokens;
    while (*cursor) {
      if (*cursor == token) {
        *cursor = token->next;
        break;
      }
      cursor = &(*cursor)->next;
    }
  }
  if (mutex) SDL_UnlockMutex(mutex);
  if (!should_free) return;
  SDL_free(token->name);
  SDL_free(token);
}

void anvil_worker_cancel_token_cancel(AnvilWorkerCancelToken *token) {
  if (token) SDL_SetAtomicInt(&token->cancelled, 1);
}

bool anvil_worker_cancel_token_cancelled(const AnvilWorkerCancelToken *token) {
  return token && SDL_GetAtomicInt((SDL_AtomicInt *)&token->cancelled) != 0;
}

const char *anvil_worker_cancel_token_name(const AnvilWorkerCancelToken *token) {
  return token && token->name ? token->name : "";
}

static void job_free(AnvilWorkerJob *job) {
  if (!job) return;
  SDL_free(job->kind);
  SDL_free(job->value);
  SDL_free(job->path);
  SDL_free(job->relpath);
  SDL_free(job->language);
  free(job->text);
  SDL_free(job->outline_query);
  SDL_free(job->usage_query);
  SDL_free(job->cancel_token);
  for (uint32_t i = 0; i < job->project_file_count; i++) {
    SDL_free((void *)job->project_files[i].path);
    SDL_free((void *)job->project_files[i].relpath);
    SDL_free((void *)job->project_files[i].fingerprint);
    SDL_free((void *)job->project_files[i].language);
    SDL_free((void *)job->project_files[i].outline_query);
    SDL_free((void *)job->project_files[i].usage_query);
  }
  SDL_free(job->project_files);
  SDL_free(job->project_root);
  for (uint32_t i = 0; i < job->project_scan_path_count; i++) SDL_free(job->project_scan_paths[i]);
  SDL_free(job->project_scan_paths);
  for (uint32_t i = 0; i < job->project_remove_path_count; i++) SDL_free(job->project_remove_paths[i]);
  SDL_free(job->project_remove_paths);
  for (uint32_t i = 0; i < job->project_excluded_path_count; i++) SDL_free(job->project_excluded_paths[i]);
  SDL_free(job->project_excluded_paths);
  for (uint32_t i = 0; i < job->project_ignore_pattern_count; i++) SDL_free(job->project_ignore_patterns[i]);
  SDL_free(job->project_ignore_patterns);
  for (uint32_t i = 0; i < job->project_language_count; i++) {
    AnvilWorkerProjectRunLanguageSpec *language = &job->project_languages[i];
    SDL_free((void *)language->id);
    SDL_free((void *)language->grammar);
    for (uint32_t p = 0; p < language->file_pattern_count; p++) SDL_free((void *)language->file_patterns[p]);
    SDL_free((void *)language->file_patterns);
    SDL_free((void *)language->outline_query);
    SDL_free((void *)language->usage_query);
  }
  SDL_free(job->project_languages);
  anvil_worker_treesitter_index_result_free(job->previous_result);
  if (job->project_builder) {
    if (job->close_project_builder) anvil_ts_project_builder_close(job->project_builder);
    else anvil_ts_project_builder_release(job->project_builder);
  }
  anvil_ts_project_snapshot_release(job->project_base_snapshot);
  anvil_ts_project_snapshot_release(job->project_snapshot_to_release);
  SDL_free(job);
}

void anvil_worker_job_retain(AnvilWorkerJob *job) {
  if (job) SDL_AtomicIncRef(&job->refcount);
}

void anvil_worker_job_release(AnvilWorkerJob *job) {
  if (job && SDL_AtomicDecRef(&job->refcount)) job_free(job);
}

static AnvilWorkerResult *result_new(const AnvilWorkerJob *job, const char *type) {
  AnvilWorkerResult *result = (AnvilWorkerResult *)SDL_calloc(1, sizeof(*result));
  if (!result) return NULL;
  result->job_id = job ? job->id : 0;
  result->kind = pool_strdup(job && job->kind ? job->kind : "");
  result->type = pool_strdup(type ? type : "result");
  if ((job && job->kind && !result->kind) || !result->type) {
    anvil_worker_result_free(result);
    return NULL;
  }
  return result;
}

static void treesitter_query_result_free(AnvilWorkerTreeSitterQueryResult *query) {
  if (!query) return;
  for (uint32_t i = 0; i < query->count; ++i) SDL_free(query->captures[i].name);
  SDL_free(query->captures);
  SDL_free(query->status);
  SDL_free(query->error);
  SDL_free(query->line_order);
  SDL_free(query->line_tree_max_end);
  memset(query, 0, sizeof(*query));
}

void anvil_worker_treesitter_index_result_retain(AnvilWorkerTreeSitterIndexResult *result) {
  if (result) SDL_AtomicIncRef(&result->refcount);
}

void anvil_worker_treesitter_index_result_free(AnvilWorkerTreeSitterIndexResult *result) {
  if (!result || !SDL_AtomicDecRef(&result->refcount)) return;
  SDL_free(result->language);
  SDL_free(result->outline_query_source);
  SDL_free(result->usage_query_source);
  treesitter_query_result_free(&result->outline);
  treesitter_query_result_free(&result->usage);
  anvil_markdown_tree_free(result->markdown_tree);
  anvil_ts_project_file_free(result->project_file);
  SDL_free(result);
}

static const AnvilWorkerTreeSitterQueryResult *treesitter_query_result_for_kind(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  if (!result || !kind) return NULL;
  if (strcmp(kind, "outline") == 0) return &result->outline;
  if (strcmp(kind, "usage") == 0 || strcmp(kind, "usages") == 0) return &result->usage;
  return NULL;
}

static AnvilWorkerTreeSitterQueryResult *treesitter_query_result_for_kind_mut(AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  if (!result || !kind) return NULL;
  if (strcmp(kind, "outline") == 0) return &result->outline;
  if (strcmp(kind, "usage") == 0 || strcmp(kind, "usages") == 0) return &result->usage;
  return NULL;
}

const char *anvil_worker_treesitter_index_result_language(const AnvilWorkerTreeSitterIndexResult *result) {
  return result && result->language ? result->language : "";
}

uint32_t anvil_worker_treesitter_index_result_byte_len(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->byte_len : 0;
}

uint32_t anvil_worker_treesitter_index_result_line_count(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->line_count : 0;
}

uint32_t anvil_worker_treesitter_index_result_capture_count(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? query->count : 0;
}

const char *anvil_worker_treesitter_index_result_status(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query && query->status ? query->status : "absent";
}

const char *anvil_worker_treesitter_index_result_error(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? query->error : NULL;
}

bool anvil_worker_treesitter_index_result_exceeded_match_limit(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? query->exceeded_match_limit : false;
}

bool anvil_worker_treesitter_index_result_line_indexed(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query && query->line_index_ready;
}

uint64_t anvil_worker_treesitter_index_result_parse_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->parse_ms : 0;
}

uint64_t anvil_worker_treesitter_index_result_block_parse_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->block_parse_ms : 0;
}

uint64_t anvil_worker_treesitter_index_result_inline_parse_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->inline_parse_ms : 0;
}

uint64_t anvil_worker_treesitter_index_result_total_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->total_ms : 0;
}

static double ticks_ns_to_ms(uint64_t ticks_ns) {
  return (double)ticks_ns / 1000000.0;
}

double anvil_worker_treesitter_index_result_precise_total_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  if (!result) return 0.0;
  return result->total_ns ? ticks_ns_to_ms(result->total_ns) : (double)result->total_ms;
}

double anvil_worker_treesitter_index_result_prepare_input_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? ticks_ns_to_ms(result->prepare_input_ns) : 0.0;
}

double anvil_worker_treesitter_index_result_parser_setup_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? ticks_ns_to_ms(result->parser_setup_ns) : 0.0;
}

double anvil_worker_treesitter_index_result_precise_parse_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  if (!result) return 0.0;
  return result->parse_ns ? ticks_ns_to_ms(result->parse_ns) : (double)result->parse_ms;
}

bool anvil_worker_treesitter_index_result_incremental(const AnvilWorkerTreeSitterIndexResult *result) {
  return result && result->incremental;
}

uint32_t anvil_worker_treesitter_index_result_reused_block_capture_count(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->reused_block_capture_count : 0;
}

uint32_t anvil_worker_treesitter_index_result_reused_inline_count(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->reused_inline_count : 0;
}

uint64_t anvil_worker_treesitter_index_result_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? query->query_ms : 0;
}

double anvil_worker_treesitter_index_result_precise_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  if (!query) return 0.0;
  return query->query_ns ? ticks_ns_to_ms(query->query_ns) : (double)query->query_ms;
}

double anvil_worker_treesitter_index_result_query_compile_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? ticks_ns_to_ms(query->query_compile_ns) : 0.0;
}

double anvil_worker_treesitter_index_result_line_index_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? ticks_ns_to_ms(query->line_index_ns) : 0.0;
}

double anvil_worker_treesitter_index_result_project_record_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? ticks_ns_to_ms(result->project_record_ns) : 0.0;
}

bool anvil_worker_treesitter_index_result_query_cache_hit(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query && query->query_cache_hit;
}

bool anvil_worker_treesitter_index_result_query_cache_miss(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query && query->query_cache_miss;
}

bool anvil_worker_treesitter_index_result_parser_reused(const AnvilWorkerTreeSitterIndexResult *result) {
  return result && result->parser_reused;
}

uint32_t anvil_worker_treesitter_index_result_capabilities(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->result_capabilities : 0;
}

uint32_t anvil_worker_treesitter_index_result_project_symbol_count(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? anvil_ts_project_file_symbol_count(result->project_file) : 0;
}

uint32_t anvil_worker_treesitter_index_result_project_usage_count(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? anvil_ts_project_file_usage_count(result->project_file) : 0;
}

AnvilTSProjectFileResult *anvil_worker_treesitter_index_result_take_project_file(AnvilWorkerTreeSitterIndexResult *result) {
  if (!result) return NULL;
  AnvilTSProjectFileResult *file = result->project_file;
  result->project_file = NULL;
  return file;
}

const char *anvil_worker_treesitter_index_result_project_path(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? anvil_ts_project_file_path(result->project_file) : NULL;
}

const char *anvil_worker_treesitter_index_result_project_relpath(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? anvil_ts_project_file_relpath(result->project_file) : NULL;
}

bool anvil_worker_treesitter_index_result_project_symbol_at(const AnvilWorkerTreeSitterIndexResult *result, uint32_t index, AnvilTSProjectSymbolView *view) {
  return result && anvil_ts_project_file_symbol_at(result->project_file, index, view);
}

bool anvil_worker_treesitter_index_result_project_usage_at(const AnvilWorkerTreeSitterIndexResult *result, uint32_t index, AnvilTSProjectUsageView *view) {
  return result && anvil_ts_project_file_usage_at(result->project_file, index, view);
}

bool anvil_worker_treesitter_index_result_capture_at(
  const AnvilWorkerTreeSitterIndexResult *result,
  const char *kind,
  uint32_t index,
  const char **name,
  uint32_t *name_len,
  uint32_t *start_byte,
  uint32_t *end_byte,
  uint32_t *start_line,
  uint32_t *start_col,
  uint32_t *end_line,
  uint32_t *end_col,
  int32_t *priority,
  uint32_t *match_id,
  uint32_t *pattern_index,
  uint32_t *capture_index,
  uint32_t *order,
  uint64_t *node_id
) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  if (!query || index >= query->count) return false;
  const AnvilWorkerTreeSitterCapture *capture = &query->captures[index];
  if (name) *name = capture->name;
  if (name_len) *name_len = capture->name_len;
  if (start_byte) *start_byte = capture->start_byte;
  if (end_byte) *end_byte = capture->end_byte;
  if (start_line) *start_line = capture->start_point.row + 1;
  if (start_col) *start_col = capture->start_point.column + 1;
  if (end_line) *end_line = capture->end_point.row + 1;
  if (end_col) *end_col = capture->end_point.column + 1;
  if (priority) *priority = capture->priority;
  if (match_id) *match_id = capture->match_id;
  if (pattern_index) *pattern_index = capture->pattern_index;
  if (capture_index) *capture_index = capture->capture_index;
  if (order) *order = capture->order;
  if (node_id) *node_id = capture->node_id;
  return true;
}

typedef struct MarkdownIdentitySlot {
  uint64_t hash;
  uint32_t index_plus_one;
  bool consumed;
} MarkdownIdentitySlot;

static uint64_t markdown_capture_hash(
  const char *name,
  uint32_t name_len,
  uint32_t start_byte,
  uint32_t end_byte
) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (uint32_t i = 0; i < name_len; i++) {
    hash ^= (unsigned char)name[i];
    hash *= UINT64_C(1099511628211);
  }
  hash ^= start_byte;
  hash *= UINT64_C(1099511628211);
  hash ^= end_byte;
  hash *= UINT64_C(1099511628211);
  return hash ? hash : 1;
}

static uint32_t markdown_map_old_start_byte(uint32_t byte, const TSInputEdit *edit) {
  if (byte < edit->start_byte ||
    (byte == edit->start_byte && edit->old_end_byte > edit->start_byte)) return byte;
  if (byte >= edit->old_end_byte) return edit->new_end_byte + (byte - edit->old_end_byte);
  return edit->new_end_byte;
}

static uint32_t markdown_map_old_end_byte(uint32_t byte, const TSInputEdit *edit) {
  if (byte <= edit->start_byte) return byte;
  if (byte >= edit->old_end_byte) return edit->new_end_byte + (byte - edit->old_end_byte);
  return edit->new_end_byte;
}

static uint64_t next_markdown_semantic_id(void) {
  return (uint64_t)(uint32_t)(SDL_AddAtomicInt(&markdown_semantic_id_sequence, 1) + 1);
}

static void reconcile_markdown_query_identities(
  AnvilWorkerTreeSitterQueryResult *current,
  const AnvilWorkerTreeSitterQueryResult *previous,
  const TSInputEdit *edit
) {
  for (uint32_t i = 0; i < current->count; i++) current->captures[i].node_id = next_markdown_semantic_id();
  if (!previous || previous->count == 0 || !edit) return;

  uint32_t capacity = 1;
  while (capacity < previous->count * 2 && capacity < UINT32_MAX / 2) capacity <<= 1;
  MarkdownIdentitySlot *slots = (MarkdownIdentitySlot *)SDL_calloc(capacity, sizeof(*slots));
  if (!slots) return;
  uint32_t mask = capacity - 1;
  for (uint32_t i = 0; i < previous->count; i++) {
    const AnvilWorkerTreeSitterCapture *capture = &previous->captures[i];
    uint32_t start = markdown_map_old_start_byte(capture->start_byte, edit);
    uint32_t end = markdown_map_old_end_byte(capture->end_byte, edit);
    uint64_t hash = markdown_capture_hash(capture->name, capture->name_len, start, end);
    uint32_t slot = (uint32_t)hash & mask;
    while (slots[slot].index_plus_one) slot = (slot + 1) & mask;
    slots[slot] = (MarkdownIdentitySlot) { .hash = hash, .index_plus_one = i + 1 };
  }
  for (uint32_t i = 0; i < current->count; i++) {
    AnvilWorkerTreeSitterCapture *capture = &current->captures[i];
    uint64_t hash = markdown_capture_hash(
      capture->name, capture->name_len, capture->start_byte, capture->end_byte
    );
    uint32_t slot = (uint32_t)hash & mask;
    while (slots[slot].index_plus_one) {
      const AnvilWorkerTreeSitterCapture *candidate =
        &previous->captures[slots[slot].index_plus_one - 1];
      if (!slots[slot].consumed && slots[slot].hash == hash &&
        candidate->name_len == capture->name_len &&
        memcmp(candidate->name, capture->name, capture->name_len) == 0 &&
        markdown_map_old_start_byte(candidate->start_byte, edit) == capture->start_byte &&
        markdown_map_old_end_byte(candidate->end_byte, edit) == capture->end_byte) {
        capture->node_id = candidate->node_id;
        slots[slot].consumed = true;
        break;
      }
      slot = (slot + 1) & mask;
    }
  }
  SDL_free(slots);
}

static bool capture_line_less(
  const AnvilWorkerTreeSitterQueryResult *query,
  uint32_t left,
  uint32_t right
) {
  const AnvilWorkerTreeSitterCapture *a = &query->captures[left];
  const AnvilWorkerTreeSitterCapture *b = &query->captures[right];
  if (a->start_point.row != b->start_point.row) return a->start_point.row < b->start_point.row;
  if (a->start_byte != b->start_byte) return a->start_byte < b->start_byte;
  return a->order < b->order;
}

static uint32_t capture_effective_end_line(const AnvilWorkerTreeSitterCapture *capture) {
  uint32_t line = capture->end_point.row + 1;
  if (capture->end_point.column == 0 && capture->end_point.row > capture->start_point.row) line--;
  return line;
}

static int capture_source_compare(const void *left, const void *right) {
  const AnvilWorkerTreeSitterCapture *a = (const AnvilWorkerTreeSitterCapture *)left;
  const AnvilWorkerTreeSitterCapture *b = (const AnvilWorkerTreeSitterCapture *)right;
  if (a->start_byte < b->start_byte) return -1;
  if (a->start_byte > b->start_byte) return 1;
  if (a->end_byte > b->end_byte) return -1;
  if (a->end_byte < b->end_byte) return 1;
  uint32_t shared = a->name_len < b->name_len ? a->name_len : b->name_len;
  int name_order = memcmp(a->name, b->name, shared);
  if (name_order != 0) return name_order;
  if (a->name_len < b->name_len) return -1;
  if (a->name_len > b->name_len) return 1;
  if (a->order < b->order) return -1;
  if (a->order > b->order) return 1;
  return 0;
}

static void normalize_capture_order(AnvilWorkerTreeSitterQueryResult *query, bool sort_by_source) {
  if (!query) return;
  if (sort_by_source && query->count > 1) {
    qsort(query->captures, query->count, sizeof(*query->captures), capture_source_compare);
  }
  for (uint32_t i = 0; i < query->count; i++) {
    query->captures[i].order = i;
    if (sort_by_source) query->captures[i].match_id = i;
  }
}

static bool enforce_query_capture_limit(
  AnvilWorkerTreeSitterQueryResult *query,
  uint32_t max_captures
) {
  if (!query || max_captures == 0 || query->count <= max_captures) return true;
  if (!query->status || (strcmp(query->status, "ready") != 0 &&
      strcmp(query->status, "limit") != 0)) return true;
  for (uint32_t i = max_captures; i < query->count; i++) {
    SDL_free(query->captures[i].name);
    query->captures[i].name = NULL;
  }
  query->count = max_captures;
  query->exceeded_match_limit = true;
  SDL_free(query->status);
  query->status = pool_strdup("limit");
  return query->status != NULL;
}

static uint32_t build_line_tree(
  AnvilWorkerTreeSitterQueryResult *query,
  uint32_t node,
  uint32_t left,
  uint32_t right
) {
  if (right - left == 1) {
    uint32_t value = capture_effective_end_line(&query->captures[query->line_order[left]]);
    query->line_tree_max_end[node] = value;
    return value;
  }
  uint32_t mid = left + (right - left) / 2;
  uint32_t a = build_line_tree(query, node * 2, left, mid);
  uint32_t b = build_line_tree(query, node * 2 + 1, mid, right);
  query->line_tree_max_end[node] = a > b ? a : b;
  return query->line_tree_max_end[node];
}

static void build_query_line_index(AnvilWorkerTreeSitterQueryResult *query) {
  if (!query || query->count == 0) {
    if (query) query->line_index_ready = true;
    return;
  }
  size_t capture_count = query->count;
  if (capture_count > SIZE_MAX / sizeof(*query->line_order) ||
    capture_count > SIZE_MAX / (4 * sizeof(*query->line_tree_max_end))) return;
  query->line_order = (uint32_t *)SDL_malloc(sizeof(*query->line_order) * capture_count);
  uint32_t *scratch = (uint32_t *)SDL_malloc(sizeof(*scratch) * capture_count);
  query->line_tree_max_end = (uint32_t *)SDL_calloc(capture_count * 4, sizeof(*query->line_tree_max_end));
  if (!query->line_order || !scratch || !query->line_tree_max_end) {
    SDL_free(query->line_order);
    SDL_free(scratch);
    SDL_free(query->line_tree_max_end);
    query->line_order = NULL;
    query->line_tree_max_end = NULL;
    return;
  }
  for (uint32_t i = 0; i < query->count; i++) query->line_order[i] = i;
  for (uint32_t width = 1; width < query->count; width *= 2) {
    for (uint32_t left = 0; left < query->count; left += width * 2) {
      uint32_t mid = left + width < query->count ? left + width : query->count;
      uint32_t right = left + width * 2 < query->count ? left + width * 2 : query->count;
      uint32_t i = left, j = mid, out = left;
      while (i < mid || j < right) {
        if (j >= right || (i < mid && capture_line_less(query, query->line_order[i], query->line_order[j]))) {
          scratch[out++] = query->line_order[i++];
        } else {
          scratch[out++] = query->line_order[j++];
        }
      }
    }
    memcpy(query->line_order, scratch, sizeof(*scratch) * query->count);
    if (width > query->count / 2) break;
  }
  SDL_free(scratch);
  build_line_tree(query, 1, 0, query->count);
  query->line_index_ready = true;
}

static void collect_line_matches(
  const AnvilWorkerTreeSitterQueryResult *query,
  uint32_t node,
  uint32_t left,
  uint32_t right,
  uint32_t line1,
  uint32_t line2,
  uint32_t *indices,
  uint32_t capacity,
  uint32_t *count
) {
  if (left >= right || query->line_tree_max_end[node] < line1) return;
  const AnvilWorkerTreeSitterCapture *first = &query->captures[query->line_order[left]];
  if (first->start_point.row + 1 > line2) return;
  if (right - left == 1) {
    uint32_t index = query->line_order[left];
    const AnvilWorkerTreeSitterCapture *capture = &query->captures[index];
    if (capture_effective_end_line(capture) >= line1 && capture->start_point.row + 1 <= line2) {
      if (*count < capacity) indices[*count] = index;
      (*count)++;
    }
    return;
  }
  uint32_t mid = left + (right - left) / 2;
  collect_line_matches(query, node * 2, left, mid, line1, line2, indices, capacity, count);
  collect_line_matches(query, node * 2 + 1, mid, right, line1, line2, indices, capacity, count);
}

uint32_t anvil_worker_treesitter_index_result_captures_for_lines(
  const AnvilWorkerTreeSitterIndexResult *result,
  const char *kind,
  uint32_t line1,
  uint32_t line2,
  uint32_t *indices,
  uint32_t capacity
) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  if (!query || line1 == 0 || line2 < line1) return 0;
  uint32_t count = 0;
  if (query->line_index_ready && query->count > 0) {
    collect_line_matches(query, 1, 0, query->count, line1, line2, indices, capacity, &count);
    return count;
  }
  for (uint32_t i = 0; i < query->count; i++) {
    const AnvilWorkerTreeSitterCapture *capture = &query->captures[i];
    if (capture_effective_end_line(capture) < line1 || capture->start_point.row + 1 > line2) continue;
    if (count < capacity) indices[count] = i;
    count++;
  }
  return count;
}

static void enqueue_result(AnvilWorkerPool *pool, AnvilWorkerResult *result) {
  if (!pool || !result) return;
  if (!pool->result_mutex) {
    anvil_worker_result_free(result);
    return;
  }
  SDL_LockMutex(pool->result_mutex);
  result->next = NULL;
  *pool->result_last = result;
  pool->result_last = &result->next;
  pool->result_count++;
  SDL_UnlockMutex(pool->result_mutex);
}

static void enqueue_simple_result(AnvilWorkerPool *pool, AnvilWorkerJob *job, const char *type) {
  AnvilWorkerResult *result = result_new(job, type);
  enqueue_result(pool, result);
}

static void running_add_locked(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  if (!pool || !job) return;
  job->running_next = pool->running_first;
  pool->running_first = job;
}

static void running_remove_locked(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  if (!pool || !job) return;
  AnvilWorkerJob **cursor = &pool->running_first;
  while (*cursor) {
    if (*cursor == job) {
      *cursor = job->running_next;
      job->running_next = NULL;
      return;
    }
    cursor = &(*cursor)->running_next;
  }
}

static void cancel_running_locked(AnvilWorkerPool *pool) {
  for (AnvilWorkerJob *job = pool ? pool->running_first : NULL; job; job = job->running_next) {
    SDL_SetAtomicInt(&job->cancel, 1);
  }
}

static bool job_cancelled(const AnvilWorkerJob *job) {
  if (!job) return false;
  if (job->cancel_parent) return job_cancelled(job->cancel_parent);
  return SDL_GetAtomicInt((SDL_AtomicInt *)&job->cancel) != 0;
}

static void sleep_cooperative(uint32_t ms) {
  if (ms > 0) SDL_Delay(ms);
}

static void run_test_echo(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  AnvilWorkerResult *result = result_new(job, "result");
  if (result) result->value = pool_strdup(job->value ? job->value : "");
  enqueue_result(pool, result);
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(pool, job, "final");
}

static void run_test_count(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  int count = job->count > 0 ? job->count : 1;
  for (int i = 1; i <= count; ++i) {
    if (job_cancelled(job)) {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
      enqueue_simple_result(pool, job, "cancelled");
      return;
    }
    AnvilWorkerResult *progress = result_new(job, "progress");
    if (progress) progress->index = i;
    enqueue_result(pool, progress);
    sleep_cooperative(job->sleep_ms);
  }
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(pool, job, "final");
}

static void run_test_fail(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
  AnvilWorkerResult *result = result_new(job, "error");
  if (result) result->error = pool_strdup(job->value ? job->value : "native worker test failure");
  enqueue_result(pool, result);
}

typedef struct AnvilWorkerTSParseRun {
  uint64_t started_ticks;
  uint32_t timeout_ms;
  AnvilWorkerJob *job;
  AnvilWorkerCancelToken *cancel_token;
  bool timed_out;
  bool cancelled;
} AnvilWorkerTSParseRun;

static bool worker_job_or_token_cancelled(AnvilWorkerJob *job, AnvilWorkerCancelToken *token) {
  return job_cancelled(job) || anvil_worker_cancel_token_cancelled(token);
}

static bool treesitter_cancel_callback(void *payload) {
  AnvilWorkerTSParseRun *run = (AnvilWorkerTSParseRun *)payload;
  return run && worker_job_or_token_cancelled(run->job, run->cancel_token);
}

static bool treesitter_deadline_callback(void *payload) {
  AnvilWorkerTSParseRun *run = (AnvilWorkerTSParseRun *)payload;
  if (!run) return false;
  if (worker_job_or_token_cancelled(run->job, run->cancel_token)) {
    run->cancelled = true;
    return true;
  }
  if (run->timeout_ms > 0 && SDL_GetTicks() - run->started_ticks >= run->timeout_ms) {
    run->timed_out = true;
    return true;
  }
  return false;
}

static bool treesitter_parse_progress(TSParseState *parse_state) {
  AnvilWorkerTSParseRun *run = (AnvilWorkerTSParseRun *) parse_state->payload;
  if (!run) return false;
  if (worker_job_or_token_cancelled(run->job, run->cancel_token)) {
    run->cancelled = true;
    return true;
  }
  if (run->timeout_ms > 0 && SDL_GetTicks() - run->started_ticks >= run->timeout_ms) {
    run->timed_out = true;
    return true;
  }
  return false;
}

static bool validate_text_buffer(char *text, size_t input_len, uint32_t *output_len, char **error) {
  if (!text || !output_len) return false;
  if (input_len > UINT32_MAX) {
    pool_set_error(error, "Tree-sitter input exceeds 4GB byte limit");
    return false;
  }
  if (memchr(text, '\0', input_len) != NULL) {
    pool_set_error(error, "Tree-sitter input contains embedded NUL");
    return false;
  }
  *output_len = (uint32_t)input_len;
  return true;
}

static bool normalize_text_in_place(char *text, size_t input_len, uint32_t *output_len, char **error) {
  if (!validate_text_buffer(text, input_len, output_len, error)) return false;
  size_t read = 0;
  size_t write = 0;
  while (read < input_len) {
    if (text[read] == '\r') {
      if (read + 1 < input_len && text[read + 1] == '\n') read++;
      text[write++] = '\n';
      read++;
    } else {
      text[write++] = text[read++];
    }
  }
  text[write] = '\0';
  *output_len = (uint32_t)write;
  return true;
}

static char *read_file_text(const char *path, size_t *text_len, uint32_t max_file_bytes, char **error) {
  if (text_len) *text_len = 0;
  if (!path || !path[0]) {
    pool_set_error(error, "Tree-sitter native index job requires text or path");
    return NULL;
  }
  FILE *fp = fopen(path, "rb");
  if (!fp) {
    pool_set_error(error, "failed to open Tree-sitter index file");
    return NULL;
  }
  if (fseek(fp, 0, SEEK_END) != 0) {
    fclose(fp);
    pool_set_error(error, "failed to seek Tree-sitter index file");
    return NULL;
  }
  long raw_size = ftell(fp);
  if (raw_size >= 0 && max_file_bytes && (uint64_t)raw_size > max_file_bytes) {
    fclose(fp);
    pool_set_error(error, "Tree-sitter index file exceeds byte limit");
    return NULL;
  }
  if (raw_size < 0 || (uint64_t)raw_size > UINT32_MAX) {
    fclose(fp);
    pool_set_error(error, raw_size < 0 ? "failed to size Tree-sitter index file" : "Tree-sitter input exceeds 4GB byte limit");
    return NULL;
  }
  if (fseek(fp, 0, SEEK_SET) != 0) {
    fclose(fp);
    pool_set_error(error, "failed to rewind Tree-sitter index file");
    return NULL;
  }
  char *text = (char *)malloc((size_t)raw_size + 1);
  if (!text) {
    fclose(fp);
    pool_set_error(error, "out of memory reading Tree-sitter index file");
    return NULL;
  }
  size_t read = fread(text, 1, (size_t)raw_size, fp);
  fclose(fp);
  if (read != (size_t)raw_size) {
    free(text);
    pool_set_error(error, "failed to read Tree-sitter index file");
    return NULL;
  }
  text[read] = '\0';
  if (text_len) *text_len = read;
  return text;
}

static const TSQuery *cached_treesitter_query(
  const AnvilTSLanguage *language,
  const char *kind,
  const char *source,
  uint32_t source_len,
  AnvilWorkerTreeSitterQueryResult *query_result,
  char **error
) {
  if (!language || !source || source_len == 0) return NULL;
  AnvilTSQueryCacheResult cached;
  if (!anvil_ts_query_cache_get(
      anvil_ts_language_ptr(language), kind ? kind : "", source, source_len, &cached
    )) {
    pool_set_error(error, "failed to allocate Tree-sitter query cache entry");
    return NULL;
  }
  if (query_result) {
    query_result->query_fingerprint = cached.fingerprint;
    query_result->query_cache_hit = cached.cache_hit;
    query_result->query_cache_miss = !cached.cache_hit;
  }
  if (!cached.query) pool_set_error(error, cached.error ? cached.error : "Tree-sitter query compilation failed");
  return cached.query;
}

static void skip_simple_query_space(
  const char *source,
  uint32_t *position,
  uint32_t end
) {
  while (*position < end) {
    char byte = source[*position];
    if (byte == ';') {
      while (*position < end && source[*position] != '\n') (*position)++;
    } else if (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n') {
      (*position)++;
    } else {
      break;
    }
  }
}

static bool simple_query_identifier_byte(char byte) {
  return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
    (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' ||
    byte == '.' || byte == '?' || byte == '!';
}

static bool query_is_capture_local_structural(
  const AnvilTSLanguage *language,
  const char *source
) {
  if (!language || !source || !source[0]) return false;
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  uint32_t source_len = (uint32_t)strlen(source);
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(language), source, source_len, &error_offset, &error_type
  );
  if (!query) return false;
  bool safe = true;
  uint32_t pattern_count = ts_query_pattern_count(query);
  for (uint32_t pattern = 0; safe && pattern < pattern_count; pattern++) {
    uint32_t position = ts_query_start_byte_for_pattern(query, pattern);
    uint32_t end = ts_query_end_byte_for_pattern(query, pattern);
    skip_simple_query_space(source, &position, end);
    if (position >= end || source[position++] != '(') { safe = false; break; }
    uint32_t node_start = position;
    while (position < end && simple_query_identifier_byte(source[position])) position++;
    if (position == node_start) { safe = false; break; }
    skip_simple_query_space(source, &position, end);
    if (position >= end || source[position++] != ')') { safe = false; break; }
    skip_simple_query_space(source, &position, end);
    if (position >= end || source[position++] != '@') { safe = false; break; }
    uint32_t capture_start = position;
    while (position < end && simple_query_identifier_byte(source[position])) position++;
    if (position == capture_start) { safe = false; break; }
    skip_simple_query_space(source, &position, end);
    if (position != end) safe = false;
  }
  ts_query_delete(query);
  return safe && pattern_count > 0;
}

static const char *treesitter_query_status_from_error(const char *error, bool exceeded_match_limit) {
  if (exceeded_match_limit) return "limit";
  if (!error) return "failed";
  if (strstr(error, "cancelled")) return "cancelled";
  if (strstr(error, "timed out")) return "timeout";
  if (strstr(error, "limit exceeded")) return "limit";
  return "failed";
}

static bool collect_treesitter_index_capture(const AnvilTSQueryCapture *capture, void *payload) {
  AnvilWorkerTreeSitterQueryResult *query = (AnvilWorkerTreeSitterQueryResult *)payload;
  if (!query || !capture) return false;
  if (query->count == query->capacity) {
    uint32_t next_capacity = query->capacity ? query->capacity * 2 : 64;
    AnvilWorkerTreeSitterCapture *next = (AnvilWorkerTreeSitterCapture *)SDL_realloc(query->captures, sizeof(*next) * next_capacity);
    if (!next) return false;
    query->captures = next;
    query->capacity = next_capacity;
  }
  AnvilWorkerTreeSitterCapture *copy = &query->captures[query->count];
  memset(copy, 0, sizeof(*copy));
  copy->name = (char *)SDL_malloc((size_t)capture->name_len + 1);
  if (!copy->name) return false;
  memcpy(copy->name, capture->name, capture->name_len);
  copy->name[capture->name_len] = '\0';
  copy->name_len = capture->name_len;
  copy->start_byte = capture->start_byte;
  copy->end_byte = capture->end_byte;
  copy->start_point = capture->start_point;
  copy->end_point = capture->end_point;
  copy->priority = capture->priority;
  copy->match_id = capture->match_id;
  copy->pattern_index = capture->pattern_index;
  copy->capture_index = capture->capture_index;
  copy->order = query->count;
  copy->node_id = capture->node_id;
  query->count++;
  return true;
}

static bool markdown_exclusion_name(const AnvilWorkerTreeSitterCapture *capture) {
  if (!capture || !capture->name) return false;
  return strcmp(capture->name, "block.code.fenced") == 0 ||
    strcmp(capture->name, "block.code.indented") == 0 ||
    strcmp(capture->name, "block.frontmatter") == 0 ||
    strcmp(capture->name, "block.html") == 0 ||
    strcmp(capture->name, "span.code") == 0 ||
    strcmp(capture->name, "span.html") == 0 ||
    strcmp(capture->name, "span.math") == 0;
}

static int markdown_exclusion_compare(const void *left, const void *right) {
  const AnvilMarkdownExclusion *a = (const AnvilMarkdownExclusion *)left;
  const AnvilMarkdownExclusion *b = (const AnvilMarkdownExclusion *)right;
  if (a->start_byte < b->start_byte) return -1;
  if (a->start_byte > b->start_byte) return 1;
  if (a->end_byte < b->end_byte) return -1;
  if (a->end_byte > b->end_byte) return 1;
  return 0;
}

static AnvilMarkdownExclusion *markdown_exclusions_build(
  const AnvilWorkerTreeSitterIndexResult *result,
  uint32_t *out_count
) {
  *out_count = 0;
  uint32_t capacity = result->outline.count + result->usage.count;
  if (capacity == 0) return NULL;
  AnvilMarkdownExclusion *ranges = (AnvilMarkdownExclusion *)SDL_malloc(sizeof(*ranges) * capacity);
  if (!ranges) {
    *out_count = UINT32_MAX;
    return NULL;
  }
  const AnvilWorkerTreeSitterQueryResult *queries[] = { &result->outline, &result->usage };
  for (uint32_t q = 0; q < 2; q++) {
    for (uint32_t i = 0; i < queries[q]->count; i++) {
      const AnvilWorkerTreeSitterCapture *capture = &queries[q]->captures[i];
      if (!markdown_exclusion_name(capture)) continue;
      ranges[(*out_count)++] = (AnvilMarkdownExclusion) {
        .start_byte = capture->start_byte,
        .end_byte = capture->end_byte,
      };
    }
  }
  if (*out_count == 0) {
    SDL_free(ranges);
    return NULL;
  }
  qsort(ranges, *out_count, sizeof(*ranges), markdown_exclusion_compare);
  uint32_t merged = 0;
  for (uint32_t i = 0; i < *out_count; i++) {
    if (merged > 0 && ranges[i].start_byte <= ranges[merged - 1].end_byte) {
      if (ranges[i].end_byte > ranges[merged - 1].end_byte) {
        ranges[merged - 1].end_byte = ranges[i].end_byte;
      }
    } else {
      ranges[merged++] = ranges[i];
    }
  }
  *out_count = merged;
  return ranges;
}

static TSPoint markdown_snapshot_point(const AnvilTSSnapshot *snapshot, uint32_t byte) {
  if (byte > snapshot->byte_len) byte = snapshot->byte_len;
  uint32_t low = 0, high = snapshot->line_count;
  while (low + 1 < high) {
    uint32_t mid = low + (high - low) / 2;
    if (snapshot->line_starts[mid] <= byte) low = mid;
    else high = mid;
  }
  return (TSPoint) { .row = low, .column = byte - snapshot->line_starts[low] };
}

typedef struct MarkdownExtensionCollector {
  AnvilWorkerTreeSitterQueryResult *query;
  const AnvilTSSnapshot *snapshot;
  uint32_t max_captures;
  bool limit_reached;
  bool out_of_memory;
} MarkdownExtensionCollector;

static bool collect_markdown_extension_capture(
  const AnvilMarkdownExtensionCapture *capture,
  void *payload
) {
  MarkdownExtensionCollector *collector = (MarkdownExtensionCollector *)payload;
  if (collector->max_captures > 0 && collector->query->count >= collector->max_captures) {
    collector->limit_reached = true;
    return false;
  }
  AnvilTSQueryCapture synthetic = {
    .name = capture->name,
    .name_len = (uint32_t)strlen(capture->name),
    .start_byte = capture->start_byte,
    .end_byte = capture->end_byte,
    .start_point = markdown_snapshot_point(collector->snapshot, capture->start_byte),
    .end_point = markdown_snapshot_point(collector->snapshot, capture->end_byte),
    .match_id = UINT32_MAX - capture->match_id,
    .pattern_index = UINT32_MAX,
    .capture_index = UINT32_MAX,
    .order = collector->query->count,
  };
  if (!collect_treesitter_index_capture(&synthetic, collector->query)) {
    collector->out_of_memory = true;
    return false;
  }
  return true;
}

static bool run_treesitter_index_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const AnvilTSLanguage *language,
  const char *field,
  const char *source,
  uint32_t source_len,
  TSTree *tree,
  const AnvilTSSnapshot *snapshot,
  uint32_t byte_start,
  uint32_t byte_end,
  AnvilWorkerTSParseRun *run,
  TSQueryCursor *cursor,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  char **fatal_error
) {
  AnvilWorkerTreeSitterQueryResult *query_result = treesitter_query_result_for_kind_mut(index_result, field);
  if (!query_result || !source || source_len == 0) return true;
  bool delete_cursor = false;
  if (!cursor) {
    cursor = ts_query_cursor_new();
    delete_cursor = true;
    if (!cursor) {
      pool_set_error(fatal_error, "failed to allocate Tree-sitter query cursor");
      return false;
    }
  }
  char *compile_error = NULL;
  uint64_t compile_started_ns = SDL_GetTicksNS();
  const TSQuery *query = cached_treesitter_query(
    language, field, source, source_len, query_result, &compile_error
  );
  query_result->query_compile_ns = SDL_GetTicksNS() - compile_started_ns;
  if (!query) {
    query_result->status = pool_strdup("failed");
    query_result->error = compile_error;
    if (delete_cursor) ts_query_cursor_delete(cursor);
    return true;
  }
  uint64_t started = SDL_GetTicks();
  uint64_t started_ns = SDL_GetTicksNS();
  bool exceeded = false;
  char *query_error = NULL;
  bool ok = anvil_ts_query_captures_in_tree_with_cursor(
    tree,
    snapshot,
    query,
    cursor,
    byte_start,
    byte_end,
    match_limit,
    max_captures,
    timeout_ms,
    collect_treesitter_index_capture,
    query_result,
    treesitter_cancel_callback,
    run,
    &exceeded,
    &query_error
  );
  query_result->query_ms = SDL_GetTicks() - started;
  query_result->query_ns = SDL_GetTicksNS() - started_ns;
  query_result->exceeded_match_limit = exceeded;
  query_result->status = pool_strdup(ok ? (exceeded ? "limit" : "ready") : treesitter_query_status_from_error(query_error, exceeded));
  if (!ok && !query_error && !query_result->status) pool_set_error(fatal_error, "out of memory storing Tree-sitter query status");
  if (query_error) {
    query_result->error = pool_strdup(query_error);
    free(query_error);
  }
  if (delete_cursor) ts_query_cursor_delete(cursor);
  return true;
}

static AnvilTSProjectCapture *project_capture_array(const AnvilWorkerTreeSitterQueryResult *query) {
  if (!query || !query->count) return NULL;
  if ((size_t)query->count > SIZE_MAX / sizeof(AnvilTSProjectCapture)) return NULL;
  AnvilTSProjectCapture *captures = (AnvilTSProjectCapture *)SDL_malloc(sizeof(*captures) * query->count);
  if (!captures) return NULL;
  for (uint32_t i = 0; i < query->count; i++) {
    const AnvilWorkerTreeSitterCapture *source = &query->captures[i];
    captures[i] = (AnvilTSProjectCapture) {
      .name = source->name,
      .name_len = source->name_len,
      .start_byte = source->start_byte,
      .end_byte = source->end_byte,
      .start_point = source->start_point,
      .end_point = source->end_point,
      .match_id = source->match_id,
      .order = source->order,
    };
  }
  return captures;
}

static bool build_project_file_records(
  AnvilWorkerTreeSitterIndexResult *result,
  const AnvilWorkerJob *job,
  const AnvilTSSnapshot *snapshot,
  char **fatal_error
) {
  AnvilTSProjectCapture *outline = project_capture_array(&result->outline);
  AnvilTSProjectCapture *usages = project_capture_array(&result->usage);
  if ((result->outline.count && !outline) || (result->usage.count && !usages)) {
    SDL_free(outline);
    SDL_free(usages);
    pool_set_error(fatal_error, "out of memory preparing native Project captures");
    return false;
  }
  char *project_error = NULL;
  result->project_file = anvil_ts_project_file_build(
    snapshot,
    job->path ? job->path : "",
    job->relpath ? job->relpath : (job->path ? job->path : ""),
    result->language,
    outline,
    result->outline.count,
    usages,
    result->usage.count,
    &project_error
  );
  SDL_free(outline);
  SDL_free(usages);
  if (!result->project_file) {
    pool_set_error(fatal_error, project_error ? project_error : "native Project record construction failed");
    free(project_error);
    return false;
  }
  return true;
}

static AnvilWorkerTreeSitterIndexResult *execute_treesitter_index_text(
  AnvilWorkerContext *context,
  AnvilWorkerJob *job,
  char **out_error,
  bool *out_cancelled
) {
  if (out_error) *out_error = NULL;
  if (out_cancelled) *out_cancelled = false;
  uint64_t job_started = SDL_GetTicks();
  uint64_t job_started_ns = SDL_GetTicksNS();
  uint64_t prepare_input_started_ns = job_started_ns;
  if (!job->language || !job->language[0]) {
    if (out_error) *out_error = pool_strdup("Tree-sitter native index job requires language");
    return NULL;
  }
  const AnvilTSLanguage *language = anvil_ts_language_by_id(job->language);
  if (!language || !anvil_ts_language_is_compatible(language)) {
    if (out_error) {
      char buffer[256];
      snprintf(buffer, sizeof(buffer), "unknown or incompatible Tree-sitter language '%s'", job->language);
      *out_error = pool_strdup(buffer);
    }
    return NULL;
  }

  char *error = NULL;
  size_t owned_text_len = 0;
  char *owned_text;
  if (job->text) {
    owned_text = job->text;
    owned_text_len = job->text_len;
    job->text = NULL;
    job->text_len = 0;
  } else {
    owned_text = read_file_text(job->path, &owned_text_len, job->max_file_bytes, &error);
  }
  if (!owned_text) {
    if (out_error) *out_error = error ? error : pool_strdup("failed to read Tree-sitter input");
    else SDL_free(error);
    return NULL;
  }

  uint32_t normalized_text_len = 0;
  if (!normalize_text_in_place(owned_text, owned_text_len, &normalized_text_len, &error)) {
    free(owned_text);
    if (out_error) *out_error = error ? error : pool_strdup("failed to normalize Tree-sitter input");
    else SDL_free(error);
    return NULL;
  }

  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_take_text(owned_text, normalized_text_len, &error);
  if (!snapshot) {
    if (out_error) *out_error = error ? pool_strdup(error) : pool_strdup("failed to create Tree-sitter snapshot");
    free(error);
    return NULL;
  }

  uint64_t prepare_input_ns = SDL_GetTicksNS() - prepare_input_started_ns;
  uint64_t parser_setup_started_ns = SDL_GetTicksNS();
  AnvilWorkerCancelToken *cancel_token = job->cancel_token ? anvil_worker_cancel_token_open(job->cancel_token) : NULL;
  bool parser_reused = context->parser != NULL;
  if (!context->parser) context->parser = ts_parser_new();
  TSParser *parser = context->parser;
  if (!parser || !ts_parser_set_language(parser, anvil_ts_language_ptr(language))) {
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (out_error) *out_error = pool_strdup("failed to initialize Tree-sitter parser");
    return NULL;
  }

  ts_parser_reset(parser);
  if (!context->query_cursor) context->query_cursor = ts_query_cursor_new();
  if (!context->query_cursor) {
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (out_error) *out_error = pool_strdup("failed to initialize Tree-sitter query cursor");
    return NULL;
  }
  uint64_t parser_setup_ns = SDL_GetTicksNS() - parser_setup_started_ns;
  AnvilWorkerTSParseRun run;
  memset(&run, 0, sizeof(run));
  run.started_ticks = SDL_GetTicks();
  run.timeout_ms = job->parse_timeout_ms ? job->parse_timeout_ms : 750;
  run.job = job;
  run.cancel_token = cancel_token;
  TSParseOptions parse_options;
  parse_options.payload = &run;
  parse_options.progress_callback = treesitter_parse_progress;
  TSInput input = anvil_ts_snapshot_input(snapshot);
  uint64_t parse_started_ns = SDL_GetTicksNS();
  TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, parse_options);
  uint64_t parse_ns = SDL_GetTicksNS() - parse_started_ns;
  uint64_t parse_ms = SDL_GetTicks() - run.started_ticks;
  if (!tree) {
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (run.cancelled || job_cancelled(job)) {
      if (out_cancelled) *out_cancelled = true;
    } else if (out_error) {
      *out_error = pool_strdup(run.timed_out ? "Tree-sitter parse timed out" : "Tree-sitter parse failed");
    }
    return NULL;
  }

  AnvilWorkerTreeSitterIndexResult *index_result = (AnvilWorkerTreeSitterIndexResult *)SDL_calloc(1, sizeof(*index_result));
  if (!index_result) {
    ts_tree_delete(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (out_error) *out_error = pool_strdup("out of memory allocating Tree-sitter index result");
    return NULL;
  }
  SDL_SetAtomicInt(&index_result->refcount, 1);
  index_result->language = pool_strdup(language->id);
  index_result->byte_len = snapshot->byte_len;
  index_result->line_count = snapshot->line_count;
  index_result->parse_ms = parse_ms;
  index_result->prepare_input_ns = prepare_input_ns;
  index_result->parser_setup_ns = parser_setup_ns;
  index_result->parse_ns = parse_ns;
  index_result->result_capabilities = job->result_capabilities;
  index_result->parser_reused = parser_reused;
  if (!index_result->language) {
    anvil_worker_treesitter_index_result_free(index_result);
    ts_tree_delete(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (out_error) *out_error = pool_strdup("out of memory storing Tree-sitter index result");
    return NULL;
  }

  bool have_fatal_error = false;
  char *fatal_error = NULL;
  if (job->outline_query) {
    run_treesitter_index_query(index_result, language, "outline", job->outline_query,
      (uint32_t)job->outline_query_len, tree, snapshot, 0, snapshot->byte_len, &run,
      context->query_cursor, job->match_limit ? job->match_limit : 50000,
      job->max_captures ? job->max_captures : 50000,
      job->query_timeout_ms ? job->query_timeout_ms : 20, &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  if (!have_fatal_error && job->usage_query) {
    run_treesitter_index_query(index_result, language, "usage", job->usage_query,
      (uint32_t)job->usage_query_len, tree, snapshot, 0, snapshot->byte_len, &run,
      context->query_cursor,
      job->usage_match_limit ? job->usage_match_limit : (job->match_limit ? job->match_limit : 50000),
      job->usage_max_captures ? job->usage_max_captures : (job->max_captures ? job->max_captures : 50000),
      job->usage_query_timeout_ms ? job->usage_query_timeout_ms : (job->query_timeout_ms ? job->query_timeout_ms : 20),
      &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  if (!have_fatal_error && (job->result_capabilities & ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS) != 0) {
    uint64_t project_record_started_ns = SDL_GetTicksNS();
    bool project_records_built = build_project_file_records(index_result, job, snapshot, &fatal_error);
    index_result->project_record_ns = SDL_GetTicksNS() - project_record_started_ns;
    have_fatal_error = !project_records_built;
  }
  if ((job->result_capabilities & ANVIL_WORKER_TS_LINE_RANGE_LOOKUP) != 0) {
    uint64_t line_index_started_ns = SDL_GetTicksNS();
    build_query_line_index(&index_result->outline);
    index_result->outline.line_index_ns = SDL_GetTicksNS() - line_index_started_ns;
    line_index_started_ns = SDL_GetTicksNS();
    build_query_line_index(&index_result->usage);
    index_result->usage.line_index_ns = SDL_GetTicksNS() - line_index_started_ns;
  } else {
    if (index_result->outline.count > 0) index_result->line_indexes_skipped++;
    if (index_result->usage.count > 0) index_result->line_indexes_skipped++;
  }
  index_result->total_ms = SDL_GetTicks() - job_started;
  index_result->total_ns = SDL_GetTicksNS() - job_started_ns;
  ts_tree_delete(tree);
  anvil_worker_cancel_token_release(cancel_token);
  anvil_ts_snapshot_free(snapshot);

  if (job_cancelled(job) || strcmp(anvil_worker_treesitter_index_result_status(index_result, "outline"), "cancelled") == 0 || strcmp(anvil_worker_treesitter_index_result_status(index_result, "usage"), "cancelled") == 0) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_free(fatal_error);
    if (out_cancelled) *out_cancelled = true;
    return NULL;
  }
  if (have_fatal_error) {
    anvil_worker_treesitter_index_result_free(index_result);
    if (out_error) *out_error = fatal_error ? fatal_error : pool_strdup("Tree-sitter native indexing failed");
    else SDL_free(fatal_error);
    return NULL;
  }
  return index_result;
}

static void run_treesitter_index_text(AnvilWorkerContext *context, AnvilWorkerJob *job) {
  AnvilWorkerPool *pool = context->pool;
  char *error = NULL;
  bool cancelled = false;
  AnvilWorkerTreeSitterIndexResult *index_result = execute_treesitter_index_text(context, job, &error, &cancelled);
  if (!index_result) {
    if (cancelled) {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
      SDL_free(error);
      enqueue_simple_result(pool, job, "cancelled");
    } else {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
      AnvilWorkerResult *result = result_new(job, "error");
      if (result) result->error = error ? error : pool_strdup("Tree-sitter native indexing failed");
      else SDL_free(error);
      enqueue_result(pool, result);
    }
    return;
  }
  AnvilWorkerResult *result = result_new(job, "result");
  if (!result) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    enqueue_simple_result(pool, job, "error");
    return;
  }
  result->treesitter_index_result = index_result;
  enqueue_result(pool, result);
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(pool, job, "final");
}

static bool markdown_extension_capture_name(const char *name) {
  return name && (strcmp(name, "span.wiki_link") == 0 || strcmp(name, "span.embed") == 0 ||
    strcmp(name, "span.highlight") == 0 || strcmp(name, "span.comment") == 0 ||
    strncmp(name, "marker.wiki_", 12) == 0 || strncmp(name, "marker.embed_", 13) == 0 ||
    strncmp(name, "marker.highlight_", 17) == 0 || strncmp(name, "marker.comment_", 15) == 0 ||
    strcmp(name, "content.target") == 0 || strcmp(name, "content.alias") == 0 ||
    strcmp(name, "content.highlight") == 0 || strcmp(name, "content.comment") == 0);
}

static bool capture_in_reused_inline_tree(
  const AnvilMarkdownTree *tree,
  uint32_t start_byte,
  uint32_t end_byte
) {
  uint32_t low = 0;
  uint32_t high = anvil_markdown_tree_inline_count(tree);
  while (low < high) {
    uint32_t mid = low + (high - low) / 2;
    TSRange range = anvil_markdown_tree_inline_source_range(tree, mid);
    if (range.start_byte <= start_byte) low = mid + 1;
    else high = mid;
  }
  if (low == 0) return false;
  uint32_t index = low - 1;
  TSRange range = anvil_markdown_tree_inline_source_range(tree, index);
  return anvil_markdown_tree_inline_was_reused(tree, index) &&
    range.start_byte <= start_byte && range.end_byte >= end_byte;
}

static bool copy_reused_inline_captures(
  AnvilWorkerTreeSitterQueryResult *query_result,
  const AnvilWorkerTreeSitterQueryResult *previous,
  const AnvilMarkdownTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
  uint32_t max_captures
) {
  if (!previous || !edit) return true;
  for (uint32_t i = 0; i < previous->count; i++) {
    const AnvilWorkerTreeSitterCapture *capture = &previous->captures[i];
    if (markdown_extension_capture_name(capture->name)) continue;
    uint32_t start = markdown_map_old_start_byte(capture->start_byte, edit);
    uint32_t end = markdown_map_old_end_byte(capture->end_byte, edit);
    if (!capture_in_reused_inline_tree(tree, start, end)) continue;
    if (max_captures > 0 && query_result->count >= max_captures) return true;
    AnvilTSQueryCapture mapped = {
      .name = capture->name,
      .name_len = capture->name_len,
      .start_byte = start,
      .end_byte = end,
      .start_point = markdown_snapshot_point(snapshot, start),
      .end_point = markdown_snapshot_point(snapshot, end),
      .priority = capture->priority,
      .match_id = capture->match_id,
      .pattern_index = capture->pattern_index,
      .capture_index = capture->capture_index,
      .order = query_result->count,
      .node_id = capture->node_id,
    };
    if (!collect_treesitter_index_capture(&mapped, query_result)) return false;
  }
  return true;
}

static bool copy_reused_block_captures(
  AnvilWorkerTreeSitterQueryResult *query_result,
  const AnvilWorkerTreeSitterQueryResult *previous,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
  uint32_t changed_start,
  uint32_t changed_end
) {
  if (!previous || !edit) return true;
  for (uint32_t i = 0; i < previous->count; i++) {
    const AnvilWorkerTreeSitterCapture *capture = &previous->captures[i];
    uint32_t start = markdown_map_old_start_byte(capture->start_byte, edit);
    uint32_t end = markdown_map_old_end_byte(capture->end_byte, edit);
    bool changed_overlap = changed_end > changed_start &&
      end >= changed_start && start < changed_end;
    if (end <= start || changed_overlap) continue;
    AnvilTSQueryCapture mapped = {
      .name = capture->name,
      .name_len = capture->name_len,
      .start_byte = start,
      .end_byte = end,
      .start_point = markdown_snapshot_point(snapshot, start),
      .end_point = markdown_snapshot_point(snapshot, end),
      .priority = capture->priority,
      .match_id = capture->match_id,
      .pattern_index = capture->pattern_index,
      .capture_index = capture->capture_index,
      .order = query_result->count,
      .node_id = capture->node_id,
    };
    if (!collect_treesitter_index_capture(&mapped, query_result)) return false;
  }
  return true;
}

static bool markdown_query_reusable(
  const AnvilWorkerTreeSitterIndexResult *previous,
  const char *field,
  const char *source
) {
  if (!previous || !source) return false;
  const char *previous_source = strcmp(field, "outline") == 0
    ? previous->outline_query_source
    : previous->usage_query_source;
  return previous_source && strcmp(previous_source, source) == 0 &&
    strcmp(anvil_worker_treesitter_index_result_status(previous, field), "ready") == 0;
}

static bool run_markdown_block_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const AnvilWorkerTreeSitterIndexResult *previous_result,
  const AnvilTSLanguage *language,
  const char *source,
  uint32_t source_len,
  AnvilMarkdownTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
  AnvilWorkerTSParseRun *run,
  TSQueryCursor *cursor,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  char **fatal_error
) {
  uint32_t changed_count = edit ? anvil_markdown_tree_changed_range_count(tree) : 0;
  if (!previous_result || !edit) {
    return run_treesitter_index_query(
      index_result, language, "outline", source, source_len,
      anvil_markdown_tree_block_tree(tree), snapshot, 0, snapshot->byte_len, run, cursor,
      match_limit, max_captures, timeout_ms, fatal_error
    );
  }

  uint32_t changed_start = snapshot->byte_len;
  uint32_t changed_end = 0;
  for (uint32_t i = 0; i < changed_count; i++) {
    TSRange range = anvil_markdown_tree_changed_range(tree, i);
    if (range.start_byte < changed_start) changed_start = range.start_byte;
    if (range.end_byte > changed_end) changed_end = range.end_byte;
  }
  if (changed_count == 0) {
    changed_start = changed_end = snapshot->byte_len;
  } else if (changed_end <= changed_start && snapshot->byte_len > 0) {
    if (changed_start >= snapshot->byte_len) changed_start = snapshot->byte_len - 1;
    changed_end = changed_start + 1;
  }
  if (changed_count > 0 && changed_start > 0) changed_start--;

  AnvilWorkerTreeSitterQueryResult *query_result = &index_result->outline;
  uint32_t count_before_reuse = query_result->count;
  if (!copy_reused_block_captures(
      query_result, &previous_result->outline, snapshot, edit,
      changed_start, changed_end)) {
    pool_set_error(fatal_error, "out of memory reusing Markdown block captures");
    return false;
  }
  index_result->reused_block_capture_count += query_result->count - count_before_reuse;
  if (changed_count == 0) {
    query_result->status = pool_strdup("ready");
    if (!query_result->status) pool_set_error(fatal_error, "out of memory storing Markdown block status");
    return true;
  }
  return run_treesitter_index_query(
    index_result, language, "outline", source, source_len,
    anvil_markdown_tree_block_tree(tree), snapshot, changed_start, changed_end, run,
    cursor, match_limit, max_captures, timeout_ms, fatal_error
  );
}

static bool run_markdown_inline_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const AnvilWorkerTreeSitterIndexResult *previous_result,
  const char *source,
  uint32_t source_len,
  AnvilMarkdownTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
  AnvilWorkerTSParseRun *run,
  TSQueryCursor *cursor,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms
) {
  AnvilWorkerTreeSitterQueryResult *query_result = &index_result->usage;
  if (!source || !source[0]) return true;
  const AnvilTSLanguage *language = anvil_ts_language_by_id("markdown_inline");
  char *compile_error = NULL;
  uint64_t compile_started_ns = SDL_GetTicksNS();
  const TSQuery *query = cached_treesitter_query(
    language, "inline", source, source_len, query_result, &compile_error
  );
  query_result->query_compile_ns = SDL_GetTicksNS() - compile_started_ns;
  if (!query) {
    query_result->status = pool_strdup("failed");
    query_result->error = compile_error;
    return true;
  }

  uint64_t started = SDL_GetTicks();
  bool ok = copy_reused_inline_captures(
    query_result,
    previous_result ? &previous_result->usage : NULL,
    tree,
    snapshot,
    edit,
    max_captures
  );
  bool exceeded_any = false;
  if (!ok) query_result->error = pool_strdup("out of memory reusing Markdown inline captures");
  uint32_t inline_count = anvil_markdown_tree_inline_count(tree);
  for (uint32_t i = 0; ok && i < inline_count; i++) {
    if (anvil_markdown_tree_inline_was_reused(tree, i)) continue;
    if (treesitter_cancel_callback(run)) {
      ok = false;
      query_result->error = pool_strdup("Tree-sitter query cancelled");
      break;
    }
    uint64_t elapsed = SDL_GetTicks() - started;
    if (timeout_ms > 0 && elapsed >= timeout_ms) {
      ok = false;
      query_result->error = pool_strdup("Tree-sitter query timed out");
      break;
    }
    if (query_result->count >= max_captures) {
      exceeded_any = true;
      break;
    }

    TSRange range = anvil_markdown_tree_inline_source_range(tree, i);
    bool exceeded = false;
    char *query_error = NULL;
    uint32_t remaining_timeout = timeout_ms > 0 ? timeout_ms - (uint32_t) elapsed : 0;
    ok = anvil_ts_query_captures_in_tree_with_cursor(
      anvil_markdown_tree_inline_tree(tree, i),
      anvil_markdown_tree_snapshot(tree),
      query,
      cursor,
      range.start_byte,
      range.end_byte,
      match_limit,
      max_captures - query_result->count,
      remaining_timeout,
      collect_treesitter_index_capture,
      query_result,
      treesitter_cancel_callback,
      run,
      &exceeded,
      &query_error
    );
    exceeded_any = exceeded_any || exceeded;
    if (!ok) {
      query_result->error = query_error ? pool_strdup(query_error) : pool_strdup("Markdown inline query failed");
      free(query_error);
      break;
    }
  }
  query_result->query_ms = SDL_GetTicks() - started;
  query_result->exceeded_match_limit = exceeded_any;
  query_result->status = pool_strdup(ok ? (exceeded_any ? "limit" : "ready")
    : treesitter_query_status_from_error(query_result->error, exceeded_any));
  return true;
}

static void run_markdown_parse(AnvilWorkerContext *context, AnvilWorkerJob *job) {
  AnvilWorkerPool *pool = context->pool;
  uint64_t job_started = SDL_GetTicks();
  char *error = NULL;
  size_t owned_text_len = 0;
  char *owned_text;
  if (job->text) {
    owned_text = job->text;
    owned_text_len = job->text_len;
    job->text = NULL;
    job->text_len = 0;
  } else {
    owned_text = read_file_text(job->path, &owned_text_len, job->max_file_bytes, &error);
  }
  if (!owned_text) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to read Markdown input");
    enqueue_result(pool, result);
    return;
  }
  uint32_t normalized_text_len = 0;
  if (!validate_text_buffer(owned_text, owned_text_len, &normalized_text_len, &error)) {
    free(owned_text);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to validate Markdown input");
    enqueue_result(pool, result);
    return;
  }
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_take_text(owned_text, normalized_text_len, &error);
  if (!snapshot) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? pool_strdup(error) : pool_strdup("failed to create Markdown snapshot");
    free(error);
    enqueue_result(pool, result);
    return;
  }

  if ((job->outline_query || job->usage_query) && !context->query_cursor) {
    context->query_cursor = ts_query_cursor_new();
    if (!context->query_cursor) {
      anvil_ts_snapshot_free(snapshot);
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
      AnvilWorkerResult *result = result_new(job, "error");
      if (result) result->error = pool_strdup("failed to initialize Markdown query cursor");
      enqueue_result(pool, result);
      return;
    }
  }
  AnvilWorkerCancelToken *cancel_token = job->cancel_token ? anvil_worker_cancel_token_open(job->cancel_token) : NULL;
  AnvilWorkerTSParseRun run;
  memset(&run, 0, sizeof(run));
  run.started_ticks = SDL_GetTicks();
  run.timeout_ms = job->parse_timeout_ms ? job->parse_timeout_ms : 750;
  run.job = job;
  run.cancel_token = cancel_token;
  AnvilMarkdownTree *tree = anvil_markdown_tree_parse_incremental(
    snapshot,
    job->previous_result ? job->previous_result->markdown_tree : NULL,
    run.timeout_ms,
    treesitter_cancel_callback,
    &run,
    &error
  );
  uint64_t parse_ms = SDL_GetTicks() - run.started_ticks;
  if (!tree) {
    bool cancelled = worker_job_or_token_cancelled(job, cancel_token) || (error && strstr(error, "cancelled"));
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (cancelled) {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
      enqueue_simple_result(pool, job, "cancelled");
      free(error);
    } else {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
      AnvilWorkerResult *result = result_new(job, "error");
      if (result) result->error = error ? pool_strdup(error) : pool_strdup("Markdown parse failed");
      free(error);
      enqueue_result(pool, result);
    }
    return;
  }

  AnvilWorkerTreeSitterIndexResult *index_result = (AnvilWorkerTreeSitterIndexResult *) SDL_calloc(1, sizeof(*index_result));
  if (!index_result) {
    anvil_markdown_tree_free(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("out of memory allocating Markdown result");
    enqueue_result(pool, result);
    return;
  }
  SDL_SetAtomicInt(&index_result->refcount, 1);
  index_result->language = pool_strdup("markdown");
  index_result->outline_query_source = pool_strdup(job->outline_query);
  index_result->usage_query_source = pool_strdup(job->usage_query);
  index_result->byte_len = snapshot->byte_len;
  index_result->line_count = snapshot->line_count;
  index_result->result_capabilities = job->result_capabilities;
  index_result->parse_ms = parse_ms;
  index_result->block_parse_ms = anvil_markdown_tree_block_parse_ms(tree);
  index_result->inline_parse_ms = anvil_markdown_tree_inline_parse_ms(tree);
  index_result->incremental = anvil_markdown_tree_was_incremental(tree);
  index_result->reused_inline_count = anvil_markdown_tree_reused_inline_count(tree);
  if (!index_result->language || (job->outline_query && !index_result->outline_query_source) ||
      (job->usage_query && !index_result->usage_query_source)) {
    anvil_worker_treesitter_index_result_free(index_result);
    anvil_markdown_tree_free(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("out of memory storing Markdown result");
    enqueue_result(pool, result);
    return;
  }
  const AnvilTSLanguage *block_language = anvil_ts_language_by_id("markdown");
  bool same_outline_query = job->previous_result && job->outline_query &&
    job->previous_result->outline_query_source &&
    strcmp(job->previous_result->outline_query_source, job->outline_query) == 0;
  index_result->outline_query_reusable = same_outline_query
    ? job->previous_result->outline_query_reusable
    : query_is_capture_local_structural(block_language, job->outline_query);
  char *fatal_error = NULL;
  TSInputEdit identity_edit = {0};
  bool have_identity_edit = anvil_markdown_tree_input_edit(tree, &identity_edit);
  const AnvilWorkerTreeSitterIndexResult *block_previous =
    index_result->outline_query_reusable &&
    markdown_query_reusable(job->previous_result, "outline", job->outline_query)
      ? job->previous_result : NULL;
  const AnvilWorkerTreeSitterIndexResult *inline_previous =
    markdown_query_reusable(job->previous_result, "usage", job->usage_query)
      ? job->previous_result : NULL;
  if (job->outline_query) {
    run_markdown_block_query(
      index_result,
      block_previous,
      block_language,
      job->outline_query,
      (uint32_t)job->outline_query_len,
      tree,
      snapshot,
      have_identity_edit ? &identity_edit : NULL,
      &run,
      context->query_cursor,
      job->match_limit ? job->match_limit : 50000,
      job->max_captures ? job->max_captures : 50000,
      job->query_timeout_ms ? job->query_timeout_ms : 20,
      &fatal_error
    );
  }
  if (!fatal_error && job->usage_query) {
    run_markdown_inline_query(
      index_result,
      inline_previous,
      job->usage_query,
      (uint32_t)job->usage_query_len,
      tree,
      snapshot,
      have_identity_edit ? &identity_edit : NULL,
      &run,
      context->query_cursor,
      job->usage_match_limit ? job->usage_match_limit : (job->match_limit ? job->match_limit : 50000),
      job->usage_max_captures ? job->usage_max_captures : (job->max_captures ? job->max_captures : 50000),
      job->usage_query_timeout_ms ? job->usage_query_timeout_ms : (job->query_timeout_ms ? job->query_timeout_ms : 20)
    );
  }

  uint32_t exclusion_count = 0;
  AnvilMarkdownExclusion *exclusions = markdown_exclusions_build(index_result, &exclusion_count);
  MarkdownExtensionCollector extension_collector = {
    .query = &index_result->usage,
    .snapshot = snapshot,
    .max_captures = job->usage_max_captures
      ? job->usage_max_captures
      : (job->max_captures ? job->max_captures : 50000),
  };
  bool extensions_ok = false;
  AnvilWorkerTSParseRun extension_run = run;
  extension_run.started_ticks = SDL_GetTicks();
  extension_run.timeout_ms = job->usage_query_timeout_ms
    ? job->usage_query_timeout_ms
    : (job->query_timeout_ms ? job->query_timeout_ms : 20);
  extension_run.timed_out = false;
  extension_run.cancelled = false;
  bool scan_extensions = job->usage_query &&
    strcmp(anvil_worker_treesitter_index_result_status(index_result, "usage"), "ready") == 0;
  if (exclusion_count == UINT32_MAX) {
    fatal_error = pool_strdup("out of memory storing Markdown extension exclusions");
  } else if (scan_extensions) {
    extensions_ok = anvil_markdown_extensions_scan(
      snapshot,
      exclusions,
      exclusion_count,
      collect_markdown_extension_capture,
      &extension_collector,
      treesitter_deadline_callback,
      &extension_run
    );
  } else {
    extensions_ok = true;
  }
  SDL_free(exclusions);
  if (extension_collector.limit_reached) {
    SDL_free(index_result->usage.status);
    index_result->usage.status = pool_strdup("limit");
    index_result->usage.exceeded_match_limit = true;
  } else if (extension_collector.out_of_memory) {
    fatal_error = pool_strdup("out of memory storing Markdown extension captures");
  } else if (!extensions_ok && extension_run.timed_out) {
    SDL_free(index_result->usage.status);
    SDL_free(index_result->usage.error);
    index_result->usage.status = pool_strdup("timeout");
    index_result->usage.error = pool_strdup("Markdown extension scan timed out");
  } else if (!extensions_ok && (extension_run.cancelled ||
      worker_job_or_token_cancelled(job, cancel_token))) {
    SDL_free(index_result->usage.status);
    index_result->usage.status = pool_strdup("cancelled");
  } else if (!extensions_ok && !fatal_error) {
    fatal_error = pool_strdup("Markdown extension scan failed");
  }

  normalize_capture_order(
    &index_result->outline, index_result->reused_block_capture_count > 0
  );
  normalize_capture_order(&index_result->usage, false);
  if (!enforce_query_capture_limit(
      &index_result->outline, job->max_captures ? job->max_captures : 50000
    )) {
    pool_set_error(&fatal_error, "out of memory storing Markdown block limit status");
  }
  reconcile_markdown_query_identities(
    &index_result->outline,
    have_identity_edit && block_previous ? &block_previous->outline : NULL,
    have_identity_edit ? &identity_edit : NULL
  );
  reconcile_markdown_query_identities(
    &index_result->usage,
    have_identity_edit && inline_previous ? &inline_previous->usage : NULL,
    have_identity_edit ? &identity_edit : NULL
  );
  if ((job->result_capabilities & ANVIL_WORKER_TS_LINE_RANGE_LOOKUP) != 0) {
    build_query_line_index(&index_result->outline);
    build_query_line_index(&index_result->usage);
  } else {
    if (index_result->outline.count > 0) index_result->line_indexes_skipped++;
    if (index_result->usage.count > 0) index_result->line_indexes_skipped++;
  }
  index_result->total_ms = SDL_GetTicks() - job_started;

  bool token_cancelled = anvil_worker_cancel_token_cancelled(cancel_token);
  anvil_worker_cancel_token_release(cancel_token);
  anvil_ts_snapshot_free(snapshot);
  bool cancelled = job_cancelled(job) || token_cancelled ||
    strcmp(anvil_worker_treesitter_index_result_status(index_result, "outline"), "cancelled") == 0 ||
    strcmp(anvil_worker_treesitter_index_result_status(index_result, "usage"), "cancelled") == 0;
  if (cancelled) {
    anvil_markdown_tree_free(tree);
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_free(fatal_error);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    return;
  }
  if (fatal_error) {
    anvil_markdown_tree_free(tree);
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = fatal_error;
    enqueue_result(pool, result);
    return;
  }

  index_result->markdown_tree = tree;
  AnvilWorkerResult *result = result_new(job, "result");
  if (!result) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    enqueue_simple_result(pool, job, "error");
    return;
  }
  result->treesitter_index_result = index_result;
  enqueue_result(pool, result);
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(pool, job, "final");
}

static AnvilWorkerTreeSitterIndexResult *execute_project_batch_file(
  AnvilWorkerContext *context,
  AnvilWorkerJob *job,
  const AnvilWorkerProjectBatchFileSpec *file,
  char **error,
  bool *cancelled
) {
  AnvilWorkerJob local = *job;
  local.cancel_parent = job;
  local.path = (char *)file->path;
  local.relpath = (char *)(file->relpath ? file->relpath : file->path);
  local.language = (char *)file->language;
  local.outline_query = (char *)file->outline_query;
  local.outline_query_len = file->outline_query_len;
  local.usage_query = (char *)file->usage_query;
  local.usage_query_len = file->usage_query_len;
  local.parse_timeout_ms = file->parse_timeout_ms;
  local.query_timeout_ms = file->query_timeout_ms;
  local.match_limit = file->match_limit;
  local.max_captures = file->max_captures;
  local.usage_query_timeout_ms = file->usage_query_timeout_ms;
  local.usage_match_limit = file->usage_match_limit;
  local.usage_max_captures = file->usage_max_captures;
  local.max_file_bytes = file->max_file_bytes;
  local.result_capabilities = ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS;
  return execute_treesitter_index_text(context, &local, error, cancelled);
}


typedef struct ProjectRunFile {
  char *path;
  char *relpath;
  char *fingerprint;
  uint64_t size;
  uint32_t language_index;
} ProjectRunFile;

typedef struct ProjectRunPatternSet {
  pcre2_code **codes;
  uint32_t count;
} ProjectRunPatternSet;

typedef struct ProjectRunWalk {
  AnvilWorkerJob *job;
  ProjectRunPatternSet ignores;
  ProjectRunPatternSet *languages;
  ProjectRunFile *files;
  uint32_t file_count;
  uint32_t file_capacity;
  uint64_t path_bytes;
  char *error;
} ProjectRunWalk;

static char *lua_pattern_to_regex(const char *pattern) {
  size_t length = strlen(pattern ? pattern : "");
  if (length > (SIZE_MAX - 8) / 4) return NULL;
  char *regex = (char *)SDL_malloc(length * 4 + 8);
  if (!regex) return NULL;
  size_t out = 0;
  for (size_t i = 0; i < length; i++) {
    char c = pattern[i];
    if (c == '%' && i + 1 < length) {
      char next = pattern[++i];
      const char *mapped = NULL;
      switch (next) {
        case 'a': mapped = "[A-Za-z]"; break;
        case 'd': mapped = "[0-9]"; break;
        case 'l': mapped = "[a-z]"; break;
        case 'u': mapped = "[A-Z]"; break;
        case 'w': mapped = "[A-Za-z0-9_]"; break;
        case 's': mapped = "\\s"; break;
        case 'x': mapped = "[A-Fa-f0-9]"; break;
        default: break;
      }
      if (mapped) {
        size_t mapped_len = strlen(mapped);
        memcpy(regex + out, mapped, mapped_len);
        out += mapped_len;
      } else {
        regex[out++] = '\\';
        regex[out++] = next;
      }
    } else if (c == '-') {
      regex[out++] = '*';
      regex[out++] = '?';
    } else {
      regex[out++] = c;
    }
  }
  regex[out] = '\0';
  return regex;
}

static void project_run_pattern_set_free(ProjectRunPatternSet *set) {
  if (!set) return;
  for (uint32_t i = 0; i < set->count; i++) pcre2_code_free(set->codes[i]);
  SDL_free(set->codes);
  memset(set, 0, sizeof(*set));
}

static bool project_run_pattern_set_compile(
  ProjectRunPatternSet *set,
  const char *const *patterns,
  uint32_t count,
  char **error
) {
  set->count = count;
  set->codes = count ? (pcre2_code **)SDL_calloc(count, sizeof(*set->codes)) : NULL;
  if (count && !set->codes) { if (error) *error = pool_strdup("out of memory compiling Project patterns"); return false; }
  for (uint32_t i = 0; i < count; i++) {
    char *regex = lua_pattern_to_regex(patterns[i]);
    if (!regex) { if (error) *error = pool_strdup("out of memory translating Project pattern"); return false; }
    int error_code = 0;
    PCRE2_SIZE error_offset = 0;
    set->codes[i] = pcre2_compile((PCRE2_SPTR)regex, PCRE2_ZERO_TERMINATED, PCRE2_UTF, &error_code, &error_offset, NULL);
    SDL_free(regex);
    if (!set->codes[i]) { if (error) *error = pool_strdup("invalid Project Lua pattern for native run"); return false; }
  }
  return true;
}

static int project_run_pattern_match(const ProjectRunPatternSet *set, const char *text) {
  int best = -1;
  size_t length = strlen(text ? text : "");
  for (uint32_t i = 0; i < set->count; i++) {
    pcre2_match_data *data = pcre2_match_data_create_from_pattern(set->codes[i], NULL);
    if (!data) continue;
    int rc = pcre2_match(set->codes[i], (PCRE2_SPTR)(text ? text : ""), length, 0, 0, data, NULL);
    if (rc >= 0) {
      PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(data);
      PCRE2_SIZE match_length = ovector[1] - ovector[0];
      if (match_length > INT_MAX) match_length = INT_MAX;
      if ((int)match_length > best) best = (int)match_length;
    }
    pcre2_match_data_free(data);
  }
  return best;
}

static bool project_run_path_belongs(const char *path, const char *root) {
  size_t root_len = strlen(root ? root : "");
  if (!path || !root_len) return false;
#ifdef _WIN32
  if (SDL_strncasecmp(path, root, root_len) != 0) return false;
#else
  if (strncmp(path, root, root_len) != 0) return false;
#endif
  char boundary = path[root_len];
  return boundary == '\0' || boundary == '/' || boundary == '\\' || root[root_len - 1] == '/' || root[root_len - 1] == '\\';
}

static bool project_run_excluded(const AnvilWorkerJob *job, const char *path) {
  for (uint32_t i = 0; i < job->project_excluded_path_count; i++) {
    if (project_run_path_belongs(path, job->project_excluded_paths[i])) return true;
  }
  return false;
}

static bool project_run_ignored(ProjectRunWalk *walk, const char *name, bool directory) {
  size_t length = strlen(name);
  char *test = directory ? (char *)SDL_malloc(length + 2) : NULL;
  const char *subject = name;
  if (directory && test) {
    memcpy(test, name, length);
    test[length] = '/';
    test[length + 1] = '\0';
    subject = test;
  }
  bool ignored = project_run_pattern_match(&walk->ignores, subject) >= 0;
  SDL_free(test);
  return ignored;
}

static uint64_t project_run_language_fingerprint(const AnvilWorkerProjectRunLanguageSpec *language) {
  uint64_t hash = UINT64_C(1469598103934665603);
#define HASH_BYTES(value, length) do { \
    const unsigned char *bytes_ = (const unsigned char *)(value); \
    for (size_t byte_ = 0; byte_ < (length); byte_++) { hash ^= bytes_[byte_]; hash *= UINT64_C(1099511628211); } \
  } while (0)
  if (language->grammar) HASH_BYTES(language->grammar, strlen(language->grammar));
  hash ^= 0xff; hash *= UINT64_C(1099511628211);
  if (language->outline_query) HASH_BYTES(language->outline_query, language->outline_query_len);
  hash ^= 0xfe; hash *= UINT64_C(1099511628211);
  if (language->usage_query) HASH_BYTES(language->usage_query, language->usage_query_len);
  hash ^= 0xfd; hash *= UINT64_C(1099511628211);
  const uint32_t limits[] = {
    language->parse_timeout_ms, language->query_timeout_ms,
    language->match_limit, language->max_captures,
    language->usage_query_timeout_ms, language->usage_match_limit,
    language->usage_max_captures,
  };
  HASH_BYTES(limits, sizeof(limits));
#undef HASH_BYTES
  return hash;
}

static bool project_run_add_file(ProjectRunWalk *walk, const char *path, const SDL_PathInfo *info) {
  int best_length = -1;
  uint32_t language_index = UINT32_MAX;
  for (uint32_t i = walk->job->project_language_count; i > 0; i--) {
    int match_length = project_run_pattern_match(&walk->languages[i - 1], path);
    if (match_length > best_length) { best_length = match_length; language_index = i - 1; }
  }
  if (language_index == UINT32_MAX || best_length < 0) return true;
  size_t path_len = strlen(path);
  if (walk->file_count >= 1000000 || path_len > UINT64_MAX - walk->path_bytes ||
      walk->path_bytes + path_len > UINT64_C(536870912)) {
    if (!walk->error) walk->error = pool_strdup("native Project enumeration exceeds its bounded file metadata limit");
    return false;
  }
  if (walk->file_count == walk->file_capacity) {
    uint32_t next = walk->file_capacity ? walk->file_capacity * 2 : 256;
    if (next < walk->file_capacity || (size_t)next > SIZE_MAX / sizeof(*walk->files)) {
      if (!walk->error) walk->error = pool_strdup("native Project enumeration file table overflow");
      return false;
    }
    ProjectRunFile *grown = (ProjectRunFile *)SDL_realloc(walk->files, (size_t)next * sizeof(*walk->files));
    if (!grown) {
      if (!walk->error) walk->error = pool_strdup("out of memory growing native Project enumeration");
      return false;
    }
    walk->files = grown;
    walk->file_capacity = next;
  }
  ProjectRunFile *file = &walk->files[walk->file_count];
  memset(file, 0, sizeof(*file));
  file->path = pool_strdup(path);
  size_t root_len = strlen(walk->job->project_root);
  const char *relative = path + root_len;
  while (*relative == '/' || *relative == '\\') relative++;
  file->relpath = pool_strdup(relative);
  char fingerprint[128];
  uint64_t language_fingerprint = project_run_language_fingerprint(&walk->job->project_languages[language_index]);
  SDL_snprintf(fingerprint, sizeof(fingerprint), "%llu:%lld:%u:%llu",
    (unsigned long long)info->size, (long long)info->modify_time, language_index,
    (unsigned long long)language_fingerprint);
  file->fingerprint = pool_strdup(fingerprint);
  file->size = info->size;
  file->language_index = language_index;
  if (!file->path || !file->relpath || !file->fingerprint) {
    SDL_free(file->path);
    SDL_free(file->relpath);
    SDL_free(file->fingerprint);
    memset(file, 0, sizeof(*file));
    if (!walk->error) walk->error = pool_strdup("out of memory copying native Project file metadata");
    return false;
  }
  walk->path_bytes += path_len;
  walk->file_count++;
  return true;
}

static SDL_EnumerationResult SDLCALL project_run_walk_callback(void *userdata, const char *dirname, const char *fname) {
  ProjectRunWalk *walk = (ProjectRunWalk *)userdata;
  if (job_cancelled(walk->job)) return SDL_ENUM_SUCCESS;
  size_t dir_len = strlen(dirname), name_len = strlen(fname);
  if (dir_len > SIZE_MAX - name_len - 1) {
    if (!walk->error) walk->error = pool_strdup("native Project enumeration path overflow");
    return SDL_ENUM_FAILURE;
  }
  char *path = (char *)SDL_malloc(dir_len + name_len + 1);
  if (!path) {
    if (!walk->error) walk->error = pool_strdup("out of memory joining native Project path");
    return SDL_ENUM_FAILURE;
  }
  memcpy(path, dirname, dir_len);
  memcpy(path + dir_len, fname, name_len + 1);
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(path, &info)) {
    if (walk->job->project_scoped && !walk->error) {
      walk->error = pool_strdup(SDL_GetError()[0] ? SDL_GetError() : "native Project path metadata failed");
    }
    SDL_free(path);
    return walk->job->project_scoped ? SDL_ENUM_FAILURE : SDL_ENUM_CONTINUE;
  }
  const char *relative = path + strlen(walk->job->project_root);
  while (*relative == '/' || *relative == '\\') relative++;
  bool ignored = project_run_ignored(walk, relative, info.type == SDL_PATHTYPE_DIRECTORY) ||
    project_run_ignored(walk, fname, info.type == SDL_PATHTYPE_DIRECTORY);
  if (project_run_excluded(walk->job, path) || ignored) {
    SDL_free(path);
    return SDL_ENUM_CONTINUE;
  }
  bool ok = true;
  if (info.type == SDL_PATHTYPE_DIRECTORY) {
    bool enumerated = SDL_EnumerateDirectory(path, project_run_walk_callback, walk);
    if (!enumerated && walk->job->project_scoped && !walk->error) {
      walk->error = pool_strdup(SDL_GetError()[0] ? SDL_GetError() : "native Project directory enumeration failed");
    }
    ok = enumerated || !walk->job->project_scoped;
  }
  else if (info.type == SDL_PATHTYPE_FILE && info.size <= walk->job->max_file_bytes) ok = project_run_add_file(walk, path, &info);
  SDL_free(path);
  return ok ? SDL_ENUM_CONTINUE : SDL_ENUM_FAILURE;
}

static bool project_run_scan_path(ProjectRunWalk *walk, const char *path) {
  if (job_cancelled(walk->job)) return true;
  if (!project_run_path_belongs(path, walk->job->project_root)) {
    if (!walk->error) walk->error = pool_strdup("native Project scan path is outside its root");
    return false;
  }
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(path, &info)) {
    if (!walk->error) walk->error = pool_strdup(SDL_GetError()[0] ? SDL_GetError() : "native Project scoped path metadata failed");
    return false;
  }
  if (project_run_excluded(walk->job, path)) return true;
  const char *relative = path + strlen(walk->job->project_root);
  while (*relative == '/' || *relative == '\\') relative++;
  const char *basename = path;
  for (const char *cursor = path; *cursor; cursor++) if (*cursor == '/' || *cursor == '\\') basename = cursor + 1;
  if (project_run_ignored(walk, relative, info.type == SDL_PATHTYPE_DIRECTORY) ||
      project_run_ignored(walk, basename, info.type == SDL_PATHTYPE_DIRECTORY)) return true;
  if (info.type == SDL_PATHTYPE_DIRECTORY) {
    bool enumerated = SDL_EnumerateDirectory(path, project_run_walk_callback, walk);
    if (!enumerated && !walk->error) {
      walk->error = pool_strdup(SDL_GetError()[0] ? SDL_GetError() : "native Project scoped directory enumeration failed");
    }
    return enumerated;
  }
  if (info.type == SDL_PATHTYPE_FILE && info.size <= walk->job->max_file_bytes) {
    return project_run_add_file(walk, path, &info);
  }
  return true;
}

static int project_run_file_compare(const void *left, const void *right) {
  const ProjectRunFile *a = (const ProjectRunFile *)left;
  const ProjectRunFile *b = (const ProjectRunFile *)right;
#ifdef _WIN32
  return SDL_strcasecmp(a->path, b->path);
#else
  return strcmp(a->path, b->path);
#endif
}

static void project_run_walk_free(ProjectRunWalk *walk) {
  if (!walk) return;
  for (uint32_t i = 0; i < walk->file_count; i++) {
    SDL_free(walk->files[i].path);
    SDL_free(walk->files[i].relpath);
    SDL_free(walk->files[i].fingerprint);
  }
  SDL_free(walk->files);
  project_run_pattern_set_free(&walk->ignores);
  if (walk->languages) {
    for (uint32_t i = 0; i < walk->job->project_language_count; i++) project_run_pattern_set_free(&walk->languages[i]);
  }
  SDL_free(walk->languages);
  SDL_free(walk->error);
  memset(walk, 0, sizeof(*walk));
}

static bool project_run_adopt_chunk(
  AnvilTSProjectBuilder *builder,
  AnvilWorkerTreeSitterIndexResult **results,
  const char **fingerprints,
  bool *usage_complete,
  uint32_t count,
  char **error
) {
  if (!count) return true;
  AnvilTSProjectFileResult **files = (AnvilTSProjectFileResult **)SDL_calloc(count, sizeof(*files));
  if (!files) { if (error) *error = pool_strdup("out of memory transferring Project run chunk"); return false; }
  for (uint32_t i = 0; i < count; i++) files[i] = anvil_worker_treesitter_index_result_take_project_file(results[i]);
  char *adopt_error = NULL;
  bool ok = anvil_ts_project_builder_adopt_batch(builder, files, fingerprints, usage_complete, count, &adopt_error);
  if (!ok) {
    for (uint32_t i = 0; i < count; i++) anvil_ts_project_file_free(files[i]);
    if (error) *error = adopt_error ? pool_strdup(adopt_error) : pool_strdup("native Project run adoption failed");
  }
  free(adopt_error);
  SDL_free(files);
  return ok;
}


typedef struct ProjectRunExecution {
  AnvilWorkerContext parent_context;
  AnvilWorkerJob *job;
  ProjectRunWalk *walk;
  AnvilTSProjectBuilder *builder;
  SDL_Mutex *mutex;
  uint32_t completed;
  uint32_t skipped;
  uint32_t reused;
  uint64_t symbols;
  uint64_t usages;
  double parse_ms;
  double project_record_ms;
  uint32_t *file_usage_counts;
  bool *file_usage_retry;
  char *fatal_error;
  uint32_t partial_publications;
  uint64_t last_partial_publication_ns;
} ProjectRunExecution;

typedef struct ProjectRunThread {
  ProjectRunExecution *execution;
  uint32_t start;
  uint32_t end;
  uint32_t usage_budget;
} ProjectRunThread;

static void project_run_set_fatal(ProjectRunExecution *execution, char *error) {
  SDL_LockMutex(execution->mutex);
  if (!execution->fatal_error) execution->fatal_error = error ? error : pool_strdup("native Project run worker failed");
  else SDL_free(error);
  SDL_UnlockMutex(execution->mutex);
  SDL_SetAtomicInt(&execution->job->cancel, 1);
}

static SDL_Semaphore *project_run_parse_slots(void) {
  if (SDL_ShouldInit(&project_parse_slots_init)) {
    int cores = SDL_GetNumLogicalCPUCores();
    uint32_t slots = cores > 2 ? (uint32_t)(cores - 2) : 1;
    if (slots > 4) slots = 4;
    project_parse_slots = SDL_CreateSemaphore(slots);
    SDL_SetInitialized(&project_parse_slots_init, project_parse_slots != NULL);
  }
  return project_parse_slots;
}

static int SDLCALL project_run_thread_main(void *userdata) {
  ProjectRunThread *thread = (ProjectRunThread *)userdata;
  ProjectRunExecution *execution = thread->execution;
  AnvilWorkerJob *job = execution->job;
  AnvilWorkerContext context = { .pool = execution->parent_context.pool };
  SDL_Semaphore *parse_slots = project_run_parse_slots();
  if (!parse_slots) {
    project_run_set_fatal(execution, pool_strdup("failed to reserve native Project parse capacity"));
    return 0;
  }
  SDL_WaitSemaphore(parse_slots);
  uint32_t usage_remaining = thread->usage_budget;
  AnvilWorkerTreeSitterIndexResult *chunk_results[64] = {0};
  const char *chunk_fingerprints[64] = {0};
  bool chunk_usage_complete[64] = {0};
  uint32_t chunk_count = 0, local_completed = 0, local_skipped = 0, local_reused = 0;
  uint64_t local_symbols = 0, local_usages = 0;
  double local_parse_ms = 0.0, local_record_ms = 0.0;
  for (uint32_t i = thread->start; !job_cancelled(job) && i < thread->end; i++) {
    ProjectRunFile *file = &execution->walk->files[i];
    AnvilWorkerProjectRunLanguageSpec *language = &job->project_languages[file->language_index];
    if (anvil_ts_project_builder_fingerprint_matches(execution->builder, file->path, file->fingerprint)) {
      local_completed++;
      local_reused++;
      continue;
    }
    AnvilWorkerProjectBatchFileSpec spec = {
      .path = file->path, .relpath = file->relpath, .fingerprint = file->fingerprint,
      .language = language->grammar, .outline_query = language->outline_query,
      .outline_query_len = language->outline_query_len,
      .usage_query = language->usage_query, .usage_query_len = language->usage_query_len,
      .parse_timeout_ms = language->parse_timeout_ms, .query_timeout_ms = language->query_timeout_ms,
      .match_limit = language->match_limit, .max_captures = language->max_captures,
      .usage_query_timeout_ms = language->usage_query_timeout_ms,
      .usage_match_limit = language->usage_match_limit,
      .usage_max_captures = language->usage_max_captures ? language->usage_max_captures : 50000,
      .max_file_bytes = job->max_file_bytes,
    };
    if (spec.usage_query) {
      if (spec.usage_max_captures > usage_remaining) spec.usage_max_captures = usage_remaining;
      if (!spec.usage_max_captures) spec.usage_query = NULL;
    }
    char *file_error = NULL;
    bool file_cancelled = false;
    AnvilWorkerTreeSitterIndexResult *result = execute_project_batch_file(&context, job, &spec, &file_error, &file_cancelled);
    if (!result) {
      if (file_cancelled || job_cancelled(job)) { SDL_free(file_error); break; }
      if (file_error && (strcmp(file_error, "failed to open Tree-sitter index file") == 0 ||
          strcmp(file_error, "Tree-sitter index file exceeds byte limit") == 0)) {
        local_skipped++;
        SDL_free(file_error);
        continue;
      }
      project_run_set_fatal(execution, file_error ? file_error : pool_strdup("native Project file indexing failed"));
      break;
    }
    const char *outline_status = anvil_worker_treesitter_index_result_status(result, "outline");
    if (!outline_status || (strcmp(outline_status, "ready") && strcmp(outline_status, "limit"))) {
      anvil_worker_treesitter_index_result_free(result);
      local_skipped++;
      continue;
    }
    const char *usage_status = anvil_worker_treesitter_index_result_status(result, "usage");
    chunk_results[chunk_count] = result;
    chunk_fingerprints[chunk_count] = file->fingerprint;
    chunk_usage_complete[chunk_count] = !language->usage_query ||
      (spec.usage_query && usage_status && strcmp(usage_status, "ready") == 0);
    chunk_count++;
    local_completed++;
    uint32_t result_symbols = anvil_worker_treesitter_index_result_project_symbol_count(result);
    uint32_t result_usages = anvil_worker_treesitter_index_result_project_usage_count(result);
    execution->file_usage_counts[i] = result_usages;
    execution->file_usage_retry[i] = !chunk_usage_complete[chunk_count - 1];
    local_symbols += result_symbols;
    local_usages += result_usages;
    usage_remaining = result_usages < usage_remaining ? usage_remaining - result_usages : 0;
    local_parse_ms += anvil_worker_treesitter_index_result_precise_parse_ms(result);
    local_record_ms += anvil_worker_treesitter_index_result_project_record_ms(result);
    uint32_t progress_files = job->project_progress_files ? job->project_progress_files : 64;
    if (progress_files > 64) progress_files = 64;
    if (chunk_count >= progress_files || i + 1 == thread->end) {
      char *adopt_error = NULL;
      if (job_cancelled(job) || !project_run_adopt_chunk(execution->builder, chunk_results, chunk_fingerprints,
          chunk_usage_complete, chunk_count, &adopt_error)) {
        if (!job_cancelled(job)) project_run_set_fatal(execution, adopt_error); else SDL_free(adopt_error);
        break;
      }
      for (uint32_t c = 0; c < chunk_count; c++) {
        anvil_worker_treesitter_index_result_free(chunk_results[c]);
        chunk_results[c] = NULL;
      }
      chunk_count = 0;
      SDL_LockMutex(execution->mutex);
      execution->completed += local_completed;
      execution->skipped += local_skipped;
      execution->reused += local_reused;
      execution->symbols += local_symbols;
      execution->usages += local_usages;
      execution->parse_ms += local_parse_ms;
      execution->project_record_ms += local_record_ms;
      local_completed = local_skipped = local_reused = 0;
      local_symbols = local_usages = 0;
      local_parse_ms = local_record_ms = 0.0;
      AnvilWorkerResult *progress = result_new(job, "progress");
      if (progress) {
        progress->files_completed = execution->completed;
        progress->files_skipped = execution->skipped;
        progress->files_reused = execution->reused;
        progress->symbols_found = execution->symbols > UINT32_MAX ? UINT32_MAX : (uint32_t)execution->symbols;
        progress->usages_found = execution->usages > UINT32_MAX ? UINT32_MAX : (uint32_t)execution->usages;
      }
      bool publish_partial = job->project_publish_partial_snapshots &&
        execution->partial_publications < 8 &&
        (!execution->last_partial_publication_ns ||
          SDL_GetTicksNS() - execution->last_partial_publication_ns >= UINT64_C(1000000000));
      if (publish_partial) {
        execution->partial_publications++;
        execution->last_partial_publication_ns = SDL_GetTicksNS();
      }
      SDL_UnlockMutex(execution->mutex);
      if (progress && publish_partial) {
        char *partial_error = NULL;
        progress->project_snapshot = anvil_ts_project_builder_snapshot(
          execution->builder, "partial", false, &partial_error);
        SDL_free(partial_error);
      }
      if (progress) enqueue_result(context.pool, progress);
    }
  }
  if (chunk_count && !job_cancelled(job)) {
    char *adopt_error = NULL;
    if (!project_run_adopt_chunk(execution->builder, chunk_results, chunk_fingerprints,
        chunk_usage_complete, chunk_count, &adopt_error)) {
      project_run_set_fatal(execution, adopt_error);
    }
  }
  for (uint32_t i = 0; i < chunk_count; i++) anvil_worker_treesitter_index_result_free(chunk_results[i]);
  SDL_LockMutex(execution->mutex);
  execution->completed += local_completed;
  execution->skipped += local_skipped;
  execution->reused += local_reused;
  execution->symbols += local_symbols;
  execution->usages += local_usages;
  execution->parse_ms += local_parse_ms;
  execution->project_record_ms += local_record_ms;
  SDL_UnlockMutex(execution->mutex);
  if (context.query_cursor) ts_query_cursor_delete(context.query_cursor);
  if (context.parser) ts_parser_delete(context.parser);
  SDL_SignalSemaphore(parse_slots);
  return 0;
}

static void run_treesitter_project_run(AnvilWorkerContext *context, AnvilWorkerJob *job) {
  uint64_t started = SDL_GetTicksNS();
  uint64_t builder_started = SDL_GetTicksNS();
  bool worker_created_builder = !job->project_builder && !job->project_builder_id;
  bool job_owns_builder = (job->project_builder && job->close_project_builder) || worker_created_builder;
  AnvilTSProjectBuilder *builder = job->project_builder ? job->project_builder
    : (job->project_builder_id ? anvil_ts_project_builder_open(job->project_builder_id)
      : anvil_ts_project_builder_create_from_snapshot(job->project_base_snapshot, job->project_usage_cap));
  double builder_ms = ticks_ns_to_ms(SDL_GetTicksNS() - builder_started);
  if (!builder) {
    AnvilTSProjectSnapshot *base_snapshot = job->project_base_snapshot;
    job->project_base_snapshot = NULL;
    anvil_ts_project_snapshot_release(base_snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("native Project run builder is unavailable");
    enqueue_result(context->pool, result);
    return;
  }
  ProjectRunWalk walk = { .job = job };
  walk.languages = job->project_language_count
    ? (ProjectRunPatternSet *)SDL_calloc(job->project_language_count, sizeof(*walk.languages)) : NULL;
  bool prepared = (!job->project_language_count || walk.languages) &&
    project_run_pattern_set_compile(&walk.ignores, (const char *const *)job->project_ignore_patterns,
      job->project_ignore_pattern_count, &walk.error);
  for (uint32_t i = 0; prepared && i < job->project_language_count; i++) {
    prepared = project_run_pattern_set_compile(&walk.languages[i], job->project_languages[i].file_patterns,
      job->project_languages[i].file_pattern_count, &walk.error);
  }
  bool enumerated = prepared;
  if (enumerated && job->project_scoped) {
    for (uint32_t i = 0; enumerated && i < job->project_scan_path_count; i++) {
      enumerated = project_run_scan_path(&walk, job->project_scan_paths[i]);
    }
  } else if (enumerated) {
    enumerated = SDL_EnumerateDirectory(job->project_root, project_run_walk_callback, &walk);
  }
  if (enumerated && walk.file_count > 1) {
    qsort(walk.files, walk.file_count, sizeof(*walk.files), project_run_file_compare);
    uint32_t out = 1;
    for (uint32_t i = 1; i < walk.file_count; i++) {
      if (project_run_file_compare(&walk.files[out - 1], &walk.files[i]) == 0) {
        SDL_free(walk.files[i].path);
        SDL_free(walk.files[i].relpath);
        SDL_free(walk.files[i].fingerprint);
      } else {
        if (out != i) walk.files[out] = walk.files[i];
        out++;
      }
    }
    walk.file_count = out;
  }
  ProjectRunExecution execution = {
    .parent_context = *context,
    .job = job,
    .walk = &walk,
    .builder = builder,
    .mutex = SDL_CreateMutex(),
    .file_usage_counts = walk.file_count ? (uint32_t *)SDL_calloc(walk.file_count, sizeof(uint32_t)) : NULL,
    .file_usage_retry = walk.file_count ? (bool *)SDL_calloc(walk.file_count, sizeof(bool)) : NULL,
  };
  if (!enumerated && !job_cancelled(job)) {
    execution.fatal_error = walk.error ? pool_strdup(walk.error) : pool_strdup(SDL_GetError());
  }
  uint32_t worker_count = 4; /* Fixed Project lane leaves capacity for interactive pool work. */
  if (worker_count > walk.file_count) worker_count = walk.file_count;
  if (!worker_count && walk.file_count) worker_count = 1;
  SDL_Thread **threads = worker_count ? (SDL_Thread **)SDL_calloc(worker_count, sizeof(*threads)) : NULL;
  ProjectRunThread *thread_data = worker_count ? (ProjectRunThread *)SDL_calloc(worker_count, sizeof(*thread_data)) : NULL;
  uint32_t *boundaries = worker_count ? (uint32_t *)SDL_calloc(worker_count + 1, sizeof(*boundaries)) : NULL;
  if (!execution.mutex || (walk.file_count && (!execution.file_usage_counts || !execution.file_usage_retry)) ||
      (worker_count && (!threads || !thread_data || !boundaries))) {
    execution.fatal_error = pool_strdup("out of memory starting native Project run workers");
  }
  if (!execution.fatal_error && worker_count) {
    uint64_t total_cost = 0, consumed_cost = 0;
    for (uint32_t i = 0; i < walk.file_count; i++) {
      uint64_t cost = walk.files[i].size > UINT64_MAX - 16384 ? UINT64_MAX : walk.files[i].size + 16384;
      total_cost = total_cost > UINT64_MAX - cost ? UINT64_MAX : total_cost + cost;
    }
    boundaries[worker_count] = walk.file_count;
    uint32_t cursor = 0;
    for (uint32_t lane = 1; lane < worker_count; lane++) {
      uint64_t target = (total_cost / worker_count) * lane + ((total_cost % worker_count) * lane) / worker_count;
      uint32_t latest = walk.file_count - (worker_count - lane);
      while (cursor < latest) {
        uint64_t cost = walk.files[cursor].size > UINT64_MAX - 16384 ? UINT64_MAX : walk.files[cursor].size + 16384;
        uint64_t next_cost = consumed_cost > UINT64_MAX - cost ? UINT64_MAX : consumed_cost + cost;
        if (next_cost > target) break;
        consumed_cost = next_cost;
        cursor++;
      }
      if (cursor < lane) {
        uint64_t cost = walk.files[cursor].size > UINT64_MAX - 16384 ? UINT64_MAX : walk.files[cursor].size + 16384;
        consumed_cost = consumed_cost > UINT64_MAX - cost ? UINT64_MAX : consumed_cost + cost;
        cursor++;
      }
      boundaries[lane] = cursor;
    }
  }
  uint32_t created = 0;
  for (uint32_t i = 0; !execution.fatal_error && i < worker_count; i++) {
    uint32_t start_index = boundaries[i];
    uint32_t end_index = boundaries[i + 1];
    uint32_t budget = worker_count ? job->project_usage_cap / worker_count : 0;
    if (i < (worker_count ? job->project_usage_cap % worker_count : 0)) budget++;
    thread_data[i] = (ProjectRunThread) { &execution, start_index, end_index, budget };
    threads[i] = SDL_CreateThread(project_run_thread_main, "anvil-project-run", &thread_data[i]);
    if (!threads[i]) {
      execution.fatal_error = pool_strdup("failed to create native Project run worker");
      SDL_SetAtomicInt(&job->cancel, 1);
      break;
    }
    created++;
  }
  for (uint32_t i = 0; i < created; i++) SDL_WaitThread(threads[i], NULL);
  /* Deterministically spend capacity left unused by another lane. Replacing
     truncated files in sorted path order preserves the global usage cap
     without making results depend on worker completion order. */
  for (uint32_t i = 0; !execution.fatal_error && !job_cancelled(job) &&
       execution.usages < job->project_usage_cap && i < walk.file_count; i++) {
    if (!execution.file_usage_retry[i]) continue;
    ProjectRunFile *file = &walk.files[i];
    AnvilWorkerProjectRunLanguageSpec *language = &job->project_languages[file->language_index];
    uint32_t available = job->project_usage_cap - (uint32_t)execution.usages;
    uint64_t retry_limit = (uint64_t)execution.file_usage_counts[i] + available;
    if (retry_limit > 50000) retry_limit = 50000;
    AnvilWorkerProjectBatchFileSpec spec = {
      .path = file->path, .relpath = file->relpath, .fingerprint = file->fingerprint,
      .language = language->grammar, .outline_query = language->outline_query,
      .outline_query_len = language->outline_query_len,
      .usage_query = language->usage_query, .usage_query_len = language->usage_query_len,
      .parse_timeout_ms = language->parse_timeout_ms, .query_timeout_ms = language->query_timeout_ms,
      .match_limit = language->match_limit, .max_captures = language->max_captures,
      .usage_query_timeout_ms = language->usage_query_timeout_ms,
      .usage_match_limit = language->usage_match_limit,
      .usage_max_captures = (uint32_t)retry_limit, .max_file_bytes = job->max_file_bytes,
    };
    char *retry_error = NULL;
    bool retry_cancelled = false;
    AnvilWorkerTreeSitterIndexResult *retry = execute_project_batch_file(context, job, &spec, &retry_error, &retry_cancelled);
    if (!retry) {
      if (retry_cancelled || job_cancelled(job)) { SDL_free(retry_error); break; }
      if (retry_error && (strcmp(retry_error, "failed to open Tree-sitter index file") == 0 ||
          strcmp(retry_error, "Tree-sitter index file exceeds byte limit") == 0)) {
        SDL_free(retry_error);
        continue;
      }
      execution.fatal_error = retry_error ? retry_error : pool_strdup("native Project usage retry failed");
      break;
    }
    const char *outline_status = anvil_worker_treesitter_index_result_status(retry, "outline");
    if (!outline_status || (strcmp(outline_status, "ready") && strcmp(outline_status, "limit"))) {
      anvil_worker_treesitter_index_result_free(retry);
      continue;
    }
    const char *usage_status = anvil_worker_treesitter_index_result_status(retry, "usage");
    bool usage_complete = !language->usage_query || (usage_status && strcmp(usage_status, "ready") == 0);
    uint32_t new_count = anvil_worker_treesitter_index_result_project_usage_count(retry);
    AnvilWorkerTreeSitterIndexResult *retry_results[1] = { retry };
    const char *retry_fingerprints[1] = { file->fingerprint };
    bool retry_complete[1] = { usage_complete };
    char *adopt_error = NULL;
    if (!project_run_adopt_chunk(builder, retry_results, retry_fingerprints, retry_complete, 1, &adopt_error)) {
      execution.fatal_error = adopt_error ? adopt_error : pool_strdup("native Project usage retry adoption failed");
      anvil_worker_treesitter_index_result_free(retry);
      break;
    }
    execution.usages -= execution.file_usage_counts[i];
    execution.usages += new_count;
    execution.file_usage_counts[i] = new_count;
    execution.file_usage_retry[i] = !usage_complete;
    execution.parse_ms += anvil_worker_treesitter_index_result_precise_parse_ms(retry);
    execution.project_record_ms += anvil_worker_treesitter_index_result_project_record_ms(retry);
    anvil_worker_treesitter_index_result_free(retry);
  }
  if (!execution.fatal_error && !job_cancelled(job) && job->project_scoped && job->project_scan_path_count) {
    const char **seen_paths = walk.file_count ? (const char **)SDL_calloc(walk.file_count, sizeof(*seen_paths)) : NULL;
    if (walk.file_count && !seen_paths) {
      execution.fatal_error = pool_strdup("out of memory preparing native Project scoped publication");
    } else {
      for (uint32_t i = 0; i < walk.file_count; i++) seen_paths[i] = walk.files[i].path;
      char *remove_error = NULL;
      if (!anvil_ts_project_builder_remove_scope_missing(builder,
          (const char *const *)job->project_scan_paths, job->project_scan_path_count,
          seen_paths, walk.file_count, &remove_error)) {
        execution.fatal_error = remove_error ? pool_strdup(remove_error) :
          pool_strdup("native Project scoped removal failed");
        free(remove_error);
      }
    }
    SDL_free(seen_paths);
  }
  if (!execution.fatal_error && !job_cancelled(job) && job->project_remove_path_count) {
    char *remove_error = NULL;
    if (!anvil_ts_project_builder_remove_scope_missing(builder,
        (const char *const *)job->project_remove_paths, job->project_remove_path_count,
        NULL, 0, &remove_error)) {
      execution.fatal_error = remove_error ? pool_strdup(remove_error) :
        pool_strdup("native Project explicit scoped removal failed");
      free(remove_error);
    }
  }
  SDL_free(threads);
  SDL_free(thread_data);
  SDL_free(boundaries);
  SDL_free(execution.file_usage_counts);
  SDL_free(execution.file_usage_retry);
  uint32_t completed = execution.completed, skipped = execution.skipped;
  uint64_t symbols = execution.symbols, usages = execution.usages;
  double parse_ms = execution.parse_ms, project_record_ms = execution.project_record_ms;
  char *fatal_error = execution.fatal_error;
  if (execution.mutex) SDL_DestroyMutex(execution.mutex);
  bool cancelled = job_cancelled(job);
  project_run_walk_free(&walk);
  if (fatal_error) {
    if (job_owns_builder) {
      job->project_builder = NULL;
      job->close_project_builder = false;
      anvil_ts_project_builder_close(builder);
    } else if (!job->project_builder) {
      anvil_ts_project_builder_release(builder);
    }
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = fatal_error; else SDL_free(fatal_error);
    enqueue_result(context->pool, result);
    return;
  }
  if (cancelled) {
    if (job_owns_builder) {
      job->project_builder = NULL;
      job->close_project_builder = false;
      anvil_ts_project_builder_close(builder);
    } else if (!job->project_builder) {
      anvil_ts_project_builder_release(builder);
    }
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(context->pool, job, "cancelled");
    return;
  }
  /* Seeding retained every shared file record needed by the builder. The old
   * immutable snapshot remains published by Lua, but the worker job no longer
   * needs to prolong its lifetime until Lua handle collection. */
  AnvilTSProjectSnapshot *base_snapshot = job->project_base_snapshot;
  job->project_base_snapshot = NULL;
  anvil_ts_project_snapshot_release(base_snapshot);
  char *snapshot_error = NULL;
  uint64_t snapshot_started = SDL_GetTicksNS();
  AnvilTSProjectSnapshot *snapshot = anvil_ts_project_builder_snapshot(builder, "ready", true, &snapshot_error);
  double snapshot_ms = ticks_ns_to_ms(SDL_GetTicksNS() - snapshot_started);
  if (!snapshot) {
    if (job_owns_builder) {
      job->project_builder = NULL;
      job->close_project_builder = false;
      anvil_ts_project_builder_close(builder);
    } else if (!job->project_builder) {
      anvil_ts_project_builder_release(builder);
    }
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *error_result = result_new(job, "error");
    if (error_result) error_result->error = snapshot_error ? snapshot_error : pool_strdup("native Project snapshot failed");
    else SDL_free(snapshot_error);
    enqueue_result(context->pool, error_result);
    return;
  }
  SDL_free(snapshot_error);
  if (job_owns_builder) {
    job->project_builder = NULL;
    job->close_project_builder = false;
    anvil_ts_project_builder_close(builder);
  } else if (!job->project_builder) {
    anvil_ts_project_builder_release(builder);
  }
  AnvilWorkerResult *result = result_new(job, "result");
  if (result) {
    result->files_completed = completed;
    result->files_skipped = skipped;
    result->files_reused = execution.reused;
    result->symbols_found = symbols > UINT32_MAX ? UINT32_MAX : (uint32_t)symbols;
    result->usages_found = usages > UINT32_MAX ? UINT32_MAX : (uint32_t)usages;
    result->batch_total_ms = ticks_ns_to_ms(SDL_GetTicksNS() - started);
    result->batch_parse_ms = parse_ms;
    result->batch_project_record_ms = project_record_ms;
    result->project_builder_ms = builder_ms;
    result->project_snapshot_ms = snapshot_ms;
    result->project_snapshot = snapshot;
  } else {
    anvil_ts_project_snapshot_release(snapshot);
  }
  enqueue_result(context->pool, result);
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(context->pool, job, "final");
}

static void run_treesitter_project_batch(AnvilWorkerContext *context, AnvilWorkerJob *job) {
  AnvilWorkerPool *pool = context->pool;
  uint64_t batch_started_ns = SDL_GetTicksNS();
  AnvilTSProjectBuilder *builder = anvil_ts_project_builder_open(job->project_builder_id);
  if (!builder) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("native Project builder is unavailable");
    enqueue_result(pool, result);
    return;
  }
  AnvilWorkerTreeSitterIndexResult **batch = job->project_file_count
    ? (AnvilWorkerTreeSitterIndexResult **)SDL_calloc(job->project_file_count, sizeof(*batch)) : NULL;
  bool *batch_usage_complete = job->project_file_count
    ? (bool *)SDL_calloc(job->project_file_count, sizeof(*batch_usage_complete)) : NULL;
  if (job->project_file_count && (!batch || !batch_usage_complete)) {
    SDL_free(batch);
    SDL_free(batch_usage_complete);
    anvil_ts_project_builder_release(builder);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("out of memory allocating native Project batch result");
    enqueue_result(pool, result);
    return;
  }
  uint32_t completed = 0, skipped = 0;
  uint32_t usage_remaining = job->project_usage_cap;
  uint64_t symbols = 0, usages = 0;
  double parse_ms = 0.0, project_record_ms = 0.0;
  char *fatal_error = NULL;
  bool cancelled = false;
  for (uint32_t i = 0; i < job->project_file_count; i++) {
    if (job_cancelled(job)) { cancelled = true; break; }
    char *file_error = NULL;
    bool file_cancelled = false;
    AnvilWorkerProjectBatchFileSpec file_spec = job->project_files[i];
    if (file_spec.usage_query) {
      if (!file_spec.usage_max_captures) file_spec.usage_max_captures = 50000;
      file_spec.usage_max_captures = file_spec.usage_max_captures < usage_remaining
        ? file_spec.usage_max_captures : usage_remaining;
      if (!file_spec.usage_max_captures) file_spec.usage_query = NULL;
    }
    AnvilWorkerTreeSitterIndexResult *result = execute_project_batch_file(context, job, &file_spec, &file_error, &file_cancelled);
    if (!result) {
      if (file_cancelled || job_cancelled(job)) {
        cancelled = true;
        SDL_free(file_error);
        break;
      }
      if (file_error && (strcmp(file_error, "failed to open Tree-sitter index file") == 0 ||
          strcmp(file_error, "Tree-sitter index file exceeds byte limit") == 0)) {
        skipped++;
        SDL_free(file_error);
        continue;
      }
      fatal_error = file_error ? file_error : pool_strdup("native Project batch file failed");
      break;
    }
    const char *outline_status = anvil_worker_treesitter_index_result_status(result, "outline");
    if (!outline_status || (strcmp(outline_status, "ready") != 0 && strcmp(outline_status, "limit") != 0)) {
      anvil_worker_treesitter_index_result_free(result);
      skipped++;
      continue;
    }
    batch[i] = result;
    const char *usage_status = anvil_worker_treesitter_index_result_status(result, "usage");
    batch_usage_complete[i] = !job->project_files[i].usage_query ||
      (file_spec.usage_query && usage_status && strcmp(usage_status, "ready") == 0);
    completed++;
    symbols += anvil_worker_treesitter_index_result_project_symbol_count(result);
    uint32_t file_usages = anvil_worker_treesitter_index_result_project_usage_count(result);
    usages += file_usages;
    usage_remaining = file_usages < usage_remaining ? usage_remaining - file_usages : 0;
    parse_ms += anvil_worker_treesitter_index_result_precise_parse_ms(result);
    project_record_ms += anvil_worker_treesitter_index_result_project_record_ms(result);
  }
  if (!cancelled && job_cancelled(job)) cancelled = true;
  if (!cancelled && !fatal_error && (symbols > UINT32_MAX || usages > UINT32_MAX)) {
    fatal_error = pool_strdup("native Project batch record count exceeds uint32 range");
  }
  if (!cancelled && !fatal_error && completed) {
    AnvilTSProjectFileResult **project_files = (AnvilTSProjectFileResult **)SDL_calloc(completed, sizeof(*project_files));
    const char **fingerprints = (const char **)SDL_calloc(completed, sizeof(*fingerprints));
    bool *usage_complete = (bool *)SDL_calloc(completed, sizeof(*usage_complete));
    if (!project_files || !fingerprints || !usage_complete) {
      fatal_error = pool_strdup("out of memory preparing native Project batch transfer");
    } else if (job_cancelled(job)) {
      cancelled = true;
    } else {
      uint32_t transfer_index = 0;
      for (uint32_t i = 0; i < job->project_file_count; i++) {
        if (!batch[i]) continue;
        project_files[transfer_index] = anvil_worker_treesitter_index_result_take_project_file(batch[i]);
        fingerprints[transfer_index] = job->project_files[i].fingerprint;
        usage_complete[transfer_index] = batch_usage_complete[i];
        transfer_index++;
      }
      char *adopt_error = NULL;
      if (!anvil_ts_project_builder_adopt_batch(builder, project_files, fingerprints, usage_complete, completed, &adopt_error)) {
        for (uint32_t i = 0; i < completed; i++) anvil_ts_project_file_free(project_files[i]);
        fatal_error = adopt_error ? pool_strdup(adopt_error) : pool_strdup("native Project batch adoption failed");
        free(adopt_error);
      }
    }
    SDL_free(project_files);
    SDL_free(fingerprints);
    SDL_free(usage_complete);
  }
  for (uint32_t i = 0; i < job->project_file_count; i++) anvil_worker_treesitter_index_result_free(batch[i]);
  SDL_free(batch);
  SDL_free(batch_usage_complete);
  anvil_ts_project_builder_release(builder);

  if (cancelled) {
    SDL_free(fatal_error);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    return;
  }
  if (fatal_error) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = fatal_error; else SDL_free(fatal_error);
    enqueue_result(pool, result);
    return;
  }
  AnvilWorkerResult *result = result_new(job, "result");
  if (result) {
    result->files_completed = completed;
    result->files_skipped = skipped;
    result->symbols_found = (uint32_t)symbols;
    result->usages_found = (uint32_t)usages;
    result->batch_total_ms = ticks_ns_to_ms(SDL_GetTicksNS() - batch_started_ns);
    result->batch_parse_ms = parse_ms;
    result->batch_project_record_ms = project_record_ms;
  }
  enqueue_result(pool, result);
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
  enqueue_simple_result(pool, job, "final");
}

static void run_job(AnvilWorkerContext *context, AnvilWorkerJob *job) {
  AnvilWorkerPool *pool = context->pool;
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_RUNNING);
  if (job_cancelled(job)) {
    if (job->project_snapshot_to_release) {
      AnvilTSProjectSnapshot *snapshot = job->project_snapshot_to_release;
      job->project_snapshot_to_release = NULL;
      anvil_ts_project_snapshot_release(snapshot);
    }
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    return;
  }

  const char *kind = job->kind ? job->kind : "";
  if (strcmp(kind, "test_echo") == 0) {
    run_test_echo(pool, job);
  } else if (strcmp(kind, "test_count") == 0) {
    run_test_count(pool, job);
  } else if (strcmp(kind, "test_fail") == 0) {
    run_test_fail(pool, job);
  } else if (strcmp(kind, "treesitter_index_text") == 0) {
    run_treesitter_index_text(context, job);
  } else if (strcmp(kind, "treesitter_project_run") == 0) {
    run_treesitter_project_run(context, job);
  } else if (strcmp(kind, "project_snapshot_release") == 0) {
    AnvilTSProjectSnapshot *snapshot = job->project_snapshot_to_release;
    job->project_snapshot_to_release = NULL;
    anvil_ts_project_snapshot_release(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_COMPLETE);
    enqueue_simple_result(context->pool, job, "final");
  } else if (strcmp(kind, "treesitter_project_batch") == 0) {
    run_treesitter_project_batch(context, job);
  } else if (strcmp(kind, "markdown_parse") == 0) {
    run_markdown_parse(context, job);
  } else {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) {
      char buffer[256];
      snprintf(buffer, sizeof(buffer), "unknown native worker job kind '%s'", kind);
      result->error = pool_strdup(buffer);
    }
    enqueue_result(pool, result);
  }
}

static bool is_project_run_job(const AnvilWorkerJob *job) {
  return job && job->kind && strcmp(job->kind, "treesitter_project_run") == 0;
}

static int worker_main(void *userdata) {
  AnvilWorkerContext *context = (AnvilWorkerContext *)userdata;
  AnvilWorkerPool *pool = context->pool;
  while (true) {
    SDL_LockMutex(pool->queue_mutex);
    AnvilWorkerJob **selected = NULL;
    while (!pool->terminate) {
      for (AnvilWorkerJob **cursor = &pool->input_first; *cursor; cursor = &(*cursor)->next) {
        if (!is_project_run_job(*cursor)) { selected = cursor; break; }
      }
      if (!selected && pool->input_first && pool->active_project_runs == 0) selected = &pool->input_first;
      if (selected) break;
      SDL_WaitCondition(pool->queue_cond, pool->queue_mutex);
    }
    if (pool->terminate && !selected) {
      SDL_UnlockMutex(pool->queue_mutex);
      if (context->query_cursor) ts_query_cursor_delete(context->query_cursor);
      if (context->parser) ts_parser_delete(context->parser);
      context->query_cursor = NULL;
      context->parser = NULL;
      return 0;
    }
    AnvilWorkerJob *job = *selected;
    *selected = job->next;
    if (!job->next) pool->input_last = selected;
    job->next = NULL;
    bool project_run = is_project_run_job(job);
    if (project_run) pool->active_project_runs++;
    running_add_locked(pool, job);
    SDL_UnlockMutex(pool->queue_mutex);

    run_job(context, job);
    int status = SDL_GetAtomicInt(&job->status);
    SDL_LockMutex(pool->result_mutex);
    if (status == ANVIL_WORKER_STATUS_COMPLETE) pool->completed++;
    else if (status == ANVIL_WORKER_STATUS_CANCELLED) pool->cancelled++;
    else if (status == ANVIL_WORKER_STATUS_FAILED) pool->failed++;
    SDL_UnlockMutex(pool->result_mutex);
    SDL_LockMutex(pool->queue_mutex);
    running_remove_locked(pool, job);
    if (project_run && pool->active_project_runs) pool->active_project_runs--;
    SDL_BroadcastCondition(pool->queue_cond);
    SDL_UnlockMutex(pool->queue_mutex);
    anvil_worker_job_release(job);
  }
}

AnvilWorkerPool *anvil_worker_pool_create(const char *name, int worker_count) {
  if (worker_count <= 0) worker_count = 1;
  if (worker_count > 64) worker_count = 64;
  AnvilWorkerPool *pool = (AnvilWorkerPool *)SDL_calloc(1, sizeof(*pool));
  if (!pool) return NULL;
  pool->name = pool_strdup(name ? name : "native-worker-pool");
  pool->worker_count = worker_count;
  pool->input_last = &pool->input_first;
  pool->result_last = &pool->result_first;
  pool->queue_mutex = SDL_CreateMutex();
  pool->queue_cond = SDL_CreateCondition();
  pool->result_mutex = SDL_CreateMutex();
  pool->workers = (SDL_Thread **)SDL_calloc((size_t)worker_count, sizeof(SDL_Thread *));
  pool->contexts = (AnvilWorkerContext *)SDL_calloc((size_t)worker_count, sizeof(*pool->contexts));
  if (!pool->name || !pool->queue_mutex || !pool->queue_cond || !pool->result_mutex || !pool->workers || !pool->contexts) {
    anvil_worker_pool_destroy(pool, true);
    return NULL;
  }
  for (int i = 0; i < worker_count; ++i) {
    char thread_name[64];
    snprintf(thread_name, sizeof(thread_name), "anvil-worker-%d", i + 1);
    pool->contexts[i].pool = pool;
    pool->workers[i] = SDL_CreateThread(worker_main, thread_name, &pool->contexts[i]);
    if (!pool->workers[i]) {
      anvil_worker_pool_destroy(pool, true);
      return NULL;
    }
  }
  return pool;
}

static AnvilWorkerJob *detach_queued_locked(AnvilWorkerPool *pool) {
  AnvilWorkerJob *job = pool->input_first;
  pool->input_first = NULL;
  pool->input_last = &pool->input_first;
  return job;
}

static void cancel_and_release_detached_queued(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  while (job) {
    AnvilWorkerJob *next = job->next;
    job->next = NULL;
    SDL_SetAtomicInt(&job->cancel, 1);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    anvil_worker_job_release(job);
    job = next;
  }
}

void anvil_worker_pool_destroy(AnvilWorkerPool *pool, bool cancel_running) {
  if (!pool) return;
  AnvilWorkerJob *detached_queued = NULL;
  if (pool->queue_mutex) {
    SDL_LockMutex(pool->queue_mutex);
    pool->terminate = true;
    if (cancel_running) {
      detached_queued = detach_queued_locked(pool);
      cancel_running_locked(pool);
    }
    if (pool->queue_cond) SDL_BroadcastCondition(pool->queue_cond);
    SDL_UnlockMutex(pool->queue_mutex);
  } else {
    pool->terminate = true;
  }

  if (detached_queued) cancel_and_release_detached_queued(pool, detached_queued);

  for (int i = 0; i < pool->worker_count; ++i) {
    if (pool->workers && pool->workers[i]) SDL_WaitThread(pool->workers[i], NULL);
  }

  AnvilWorkerResult *result = NULL;
  if (pool->result_mutex) {
    while ((result = anvil_worker_pool_pop_result(pool)) != NULL) anvil_worker_result_free(result);
  } else {
    result = pool->result_first;
    while (result) {
      AnvilWorkerResult *next = result->next;
      anvil_worker_result_free(result);
      result = next;
    }
  }

  if (pool->queue_cond) SDL_DestroyCondition(pool->queue_cond);
  if (pool->queue_mutex) SDL_DestroyMutex(pool->queue_mutex);
  if (pool->result_mutex) SDL_DestroyMutex(pool->result_mutex);
  SDL_free(pool->workers);
  SDL_free(pool->contexts);
  SDL_free(pool->name);
  SDL_free(pool);
}

AnvilWorkerJob *anvil_worker_pool_submit(AnvilWorkerPool *pool, const AnvilWorkerJobSpec *spec, char **error) {
  if (error) *error = NULL;
  if (!pool || !spec || !spec->kind || !spec->kind[0]) {
    pool_set_error(error, "invalid worker job spec");
    return NULL;
  }
  if (spec->project_file_count > 4096 || spec->project_language_count > 256 ||
      spec->project_scan_path_count > 65536 || spec->project_remove_path_count > 65536 ||
      spec->project_excluded_path_count > 65536 ||
      spec->project_ignore_pattern_count > 4096) {
    pool_set_error(error, "native Project job input exceeds its bounded table limit");
    return NULL;
  }
  if ((spec->project_scan_path_count && !spec->project_scan_paths) ||
      (spec->project_remove_path_count && !spec->project_remove_paths) ||
      (spec->project_excluded_path_count && !spec->project_excluded_paths) ||
      (spec->project_ignore_pattern_count && !spec->project_ignore_patterns) ||
      (spec->project_language_count && !spec->project_languages)) {
    pool_set_error(error, "invalid native Project run tables");
    return NULL;
  }
  if (strcmp(spec->kind, "treesitter_project_run") == 0) {
    if (!spec->project_root || !spec->project_root[0]) {
      pool_set_error(error, "native Project run requires a root");
      return NULL;
    }
    for (uint32_t i = 0; i < spec->project_scan_path_count; i++) {
      if (!project_run_path_belongs(spec->project_scan_paths[i], spec->project_root)) {
        pool_set_error(error, "native Project scan path is outside its root");
        return NULL;
      }
    }
    for (uint32_t i = 0; i < spec->project_remove_path_count; i++) {
      if (!project_run_path_belongs(spec->project_remove_paths[i], spec->project_root)) {
        pool_set_error(error, "native Project removal path is outside its root");
        return NULL;
      }
    }
  }
  if (spec->text_len > UINT32_MAX || spec->outline_query_len > UINT32_MAX || spec->usage_query_len > UINT32_MAX) {
    pool_set_error(error, "Tree-sitter worker input exceeds 4GB byte limit");
    return NULL;
  }
  size_t outline_query_len = spec->outline_query
    ? (spec->outline_query_len ? spec->outline_query_len : strlen(spec->outline_query)) : 0;
  size_t usage_query_len = spec->usage_query
    ? (spec->usage_query_len ? spec->usage_query_len : strlen(spec->usage_query)) : 0;
  if ((spec->outline_query && memchr(spec->outline_query, '\0', outline_query_len) != NULL) ||
      (spec->usage_query && memchr(spec->usage_query, '\0', usage_query_len) != NULL)) {
    pool_set_error(error, "Tree-sitter query contains embedded NUL");
    return NULL;
  }
  AnvilWorkerJob *job = (AnvilWorkerJob *)SDL_calloc(1, sizeof(*job));
  if (!job) {
    pool_set_error(error, "out of memory allocating worker job");
    return NULL;
  }
  SDL_SetAtomicInt(&job->refcount, 2); /* Lua handle + queue/worker ownership. */
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_QUEUED);
  job->kind = pool_strdup(spec->kind);
  job->value = pool_strdup(spec->value);
  job->count = spec->count;
  job->sleep_ms = spec->sleep_ms;
  job->path = pool_strdup(spec->path);
  job->relpath = pool_strdup(spec->relpath);
  job->language = pool_strdup(spec->language);
  job->text_len = spec->text ? (spec->text_len ? spec->text_len : strlen(spec->text)) : 0;
  job->outline_query_len = outline_query_len;
  job->usage_query_len = usage_query_len;
  job->text = spec->text ? pool_textdup(spec->text, job->text_len) : NULL;
  job->outline_query = spec->outline_query ? pool_memdup0(spec->outline_query, job->outline_query_len) : NULL;
  job->usage_query = spec->usage_query ? pool_memdup0(spec->usage_query, job->usage_query_len) : NULL;
  job->cancel_token = pool_strdup(spec->cancel_token);
  job->parse_timeout_ms = spec->parse_timeout_ms;
  job->query_timeout_ms = spec->query_timeout_ms;
  job->match_limit = spec->match_limit;
  job->max_captures = spec->max_captures;
  job->usage_query_timeout_ms = spec->usage_query_timeout_ms;
  job->usage_match_limit = spec->usage_match_limit;
  job->usage_max_captures = spec->usage_max_captures;
  job->max_file_bytes = spec->max_file_bytes;
  job->result_capabilities = spec->result_capabilities_set
    ? spec->result_capabilities
    : (ANVIL_WORKER_TS_CAPTURE_PAGING | ANVIL_WORKER_TS_LINE_RANGE_LOOKUP);
  job->previous_result = spec->previous_result;
  anvil_worker_treesitter_index_result_retain(job->previous_result);
  job->project_builder_id = spec->project_builder_id;
  job->project_builder = spec->project_builder;
  anvil_ts_project_builder_retain(job->project_builder);
  job->project_base_snapshot = spec->project_base_snapshot;
  anvil_ts_project_snapshot_retain(job->project_base_snapshot);
  job->project_snapshot_to_release = spec->project_snapshot_to_release;
  anvil_ts_project_snapshot_retain(job->project_snapshot_to_release);
  job->project_usage_cap = spec->project_usage_cap;
  job->project_root = pool_strdup(spec->project_root);
  job->project_scoped = spec->project_scoped;
  job->project_progress_files = spec->project_progress_files ? spec->project_progress_files : 64;
  job->project_publish_partial_snapshots = spec->project_publish_partial_snapshots;
  job->project_file_count = spec->project_file_count;
  if (job->project_file_count) {
    if (!spec->project_files || (size_t)job->project_file_count > SIZE_MAX / sizeof(*job->project_files)) {
      anvil_worker_job_release(job); anvil_worker_job_release(job);
      pool_set_error(error, "invalid native Project batch files");
      return NULL;
    }
    job->project_files = (AnvilWorkerProjectBatchFileSpec *)SDL_calloc(job->project_file_count, sizeof(*job->project_files));
    if (!job->project_files) {
      anvil_worker_job_release(job); anvil_worker_job_release(job);
      pool_set_error(error, "out of memory copying native Project batch files");
      return NULL;
    }
    for (uint32_t i = 0; i < job->project_file_count; i++) {
      const AnvilWorkerProjectBatchFileSpec *source = &spec->project_files[i];
      AnvilWorkerProjectBatchFileSpec *target = &job->project_files[i];
      size_t outline_len = source->outline_query ? (source->outline_query_len ? source->outline_query_len : strlen(source->outline_query)) : 0;
      size_t usage_len = source->usage_query ? (source->usage_query_len ? source->usage_query_len : strlen(source->usage_query)) : 0;
      if (outline_len > UINT32_MAX || usage_len > UINT32_MAX ||
          (source->outline_query && memchr(source->outline_query, '\0', outline_len)) ||
          (source->usage_query && memchr(source->usage_query, '\0', usage_len))) {
        anvil_worker_job_release(job); anvil_worker_job_release(job);
        pool_set_error(error, "invalid native Project batch query");
        return NULL;
      }
      target->path = pool_strdup(source->path);
      target->relpath = pool_strdup(source->relpath);
      target->fingerprint = pool_strdup(source->fingerprint);
      target->language = pool_strdup(source->language);
      target->outline_query = source->outline_query ? pool_memdup0(source->outline_query, outline_len) : NULL;
      target->outline_query_len = outline_len;
      target->usage_query = source->usage_query ? pool_memdup0(source->usage_query, usage_len) : NULL;
      target->usage_query_len = usage_len;
      target->parse_timeout_ms = source->parse_timeout_ms;
      target->query_timeout_ms = source->query_timeout_ms;
      target->match_limit = source->match_limit;
      target->max_captures = source->max_captures;
      target->usage_query_timeout_ms = source->usage_query_timeout_ms;
      target->usage_match_limit = source->usage_match_limit;
      target->usage_max_captures = source->usage_max_captures;
      target->max_file_bytes = source->max_file_bytes;
      if (!target->path || !target->language || !target->outline_query ||
          (source->relpath && !target->relpath) || (source->fingerprint && !target->fingerprint) ||
          (source->usage_query && !target->usage_query)) {
        anvil_worker_job_release(job); anvil_worker_job_release(job);
        pool_set_error(error, "out of memory copying native Project batch file");
        return NULL;
      }
    }
  }
  job->project_scan_path_count = spec->project_scan_path_count;
  if (job->project_scan_path_count) {
    job->project_scan_paths = (char **)SDL_calloc(job->project_scan_path_count, sizeof(*job->project_scan_paths));
    if (!job->project_scan_paths) goto project_run_copy_oom;
    for (uint32_t i = 0; i < job->project_scan_path_count; i++) {
      job->project_scan_paths[i] = pool_strdup(spec->project_scan_paths[i]);
      if (!job->project_scan_paths[i]) goto project_run_copy_oom;
    }
  }
  job->project_remove_path_count = spec->project_remove_path_count;
  if (job->project_remove_path_count) {
    job->project_remove_paths = (char **)SDL_calloc(job->project_remove_path_count, sizeof(*job->project_remove_paths));
    if (!job->project_remove_paths) goto project_run_copy_oom;
    for (uint32_t i = 0; i < job->project_remove_path_count; i++) {
      job->project_remove_paths[i] = pool_strdup(spec->project_remove_paths[i]);
      if (!job->project_remove_paths[i]) goto project_run_copy_oom;
    }
  }
  job->project_excluded_path_count = spec->project_excluded_path_count;
  if (job->project_excluded_path_count) {
    job->project_excluded_paths = (char **)SDL_calloc(job->project_excluded_path_count, sizeof(*job->project_excluded_paths));
    if (!job->project_excluded_paths) goto project_run_copy_oom;
    for (uint32_t i = 0; i < job->project_excluded_path_count; i++) {
      job->project_excluded_paths[i] = pool_strdup(spec->project_excluded_paths[i]);
      if (!job->project_excluded_paths[i]) goto project_run_copy_oom;
    }
  }
  job->project_ignore_pattern_count = spec->project_ignore_pattern_count;
  if (job->project_ignore_pattern_count) {
    job->project_ignore_patterns = (char **)SDL_calloc(job->project_ignore_pattern_count, sizeof(*job->project_ignore_patterns));
    if (!job->project_ignore_patterns) goto project_run_copy_oom;
    for (uint32_t i = 0; i < job->project_ignore_pattern_count; i++) {
      job->project_ignore_patterns[i] = pool_strdup(spec->project_ignore_patterns[i]);
      if (!job->project_ignore_patterns[i]) goto project_run_copy_oom;
    }
  }
  job->project_language_count = spec->project_language_count;
  if (job->project_language_count) {
    job->project_languages = (AnvilWorkerProjectRunLanguageSpec *)SDL_calloc(job->project_language_count, sizeof(*job->project_languages));
    if (!job->project_languages) goto project_run_copy_oom;
    for (uint32_t i = 0; i < job->project_language_count; i++) {
      const AnvilWorkerProjectRunLanguageSpec *source = &spec->project_languages[i];
      AnvilWorkerProjectRunLanguageSpec *target = &job->project_languages[i];
      *target = *source;
      target->id = pool_strdup(source->id);
      target->grammar = pool_strdup(source->grammar);
      target->outline_query = source->outline_query ? pool_memdup0(source->outline_query,
        source->outline_query_len ? source->outline_query_len : strlen(source->outline_query)) : NULL;
      target->usage_query = source->usage_query ? pool_memdup0(source->usage_query,
        source->usage_query_len ? source->usage_query_len : strlen(source->usage_query)) : NULL;
      target->file_patterns = source->file_pattern_count
        ? (const char *const *)SDL_calloc(source->file_pattern_count, sizeof(*target->file_patterns)) : NULL;
      if (!target->id || !target->grammar || !target->outline_query ||
          (source->usage_query && !target->usage_query) || (source->file_pattern_count && !target->file_patterns)) goto project_run_copy_oom;
      for (uint32_t p = 0; p < source->file_pattern_count; p++) {
        ((char **)target->file_patterns)[p] = pool_strdup(source->file_patterns[p]);
        if (!target->file_patterns[p]) goto project_run_copy_oom;
      }
    }
  }
  if (!job->kind || (spec->value && !job->value) || (spec->path && !job->path) ||
      (spec->relpath && !job->relpath) || (spec->language && !job->language) || (spec->text && !job->text) ||
      (spec->outline_query && !job->outline_query) || (spec->usage_query && !job->usage_query) ||
      (spec->cancel_token && !job->cancel_token) || (spec->project_root && !job->project_root)) {
    anvil_worker_job_release(job);
    anvil_worker_job_release(job);
    pool_set_error(error, "out of memory copying worker job spec");
    return NULL;
  }
  goto project_run_copy_done;
project_run_copy_oom:
  anvil_worker_job_release(job);
  anvil_worker_job_release(job);
  pool_set_error(error, "out of memory copying native Project run spec");
  return NULL;
project_run_copy_done:

  /* Submission has completed all fallible copies. From this point the job may
   * own the caller's builder reference and will close it on every terminal
   * path, including cancellation before execution. */
  job->close_project_builder = spec->transfer_project_builder && job->project_builder != NULL;

  SDL_LockMutex(pool->queue_mutex);
  if (pool->terminate) {
    SDL_UnlockMutex(pool->queue_mutex);
    job->close_project_builder = false;
    anvil_worker_job_release(job);
    anvil_worker_job_release(job);
    pool_set_error(error, "worker pool is shutting down");
    return NULL;
  }
  job->id = ++pool->next_job_id;
  *pool->input_last = job;
  pool->input_last = &job->next;
  pool->submitted++;
  SDL_SignalCondition(pool->queue_cond);
  SDL_UnlockMutex(pool->queue_mutex);
  return job;
}

bool anvil_worker_pool_cancel(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  (void)pool;
  if (!job) return false;
  int status = SDL_GetAtomicInt(&job->status);
  if (status == ANVIL_WORKER_STATUS_COMPLETE || status == ANVIL_WORKER_STATUS_CANCELLED || status == ANVIL_WORKER_STATUS_FAILED) return false;
  SDL_SetAtomicInt(&job->cancel, 1);
  return true;
}

AnvilWorkerResult *anvil_worker_pool_pop_result(AnvilWorkerPool *pool) {
  if (!pool || !pool->result_mutex) return NULL;
  SDL_LockMutex(pool->result_mutex);
  AnvilWorkerResult *result = pool->result_first;
  if (result) {
    pool->result_first = result->next;
    if (!pool->result_first) pool->result_last = &pool->result_first;
    result->next = NULL;
    if (pool->result_count > 0) pool->result_count--;
  }
  SDL_UnlockMutex(pool->result_mutex);
  return result;
}

void anvil_worker_result_free(AnvilWorkerResult *result) {
  if (!result) return;
  SDL_free(result->kind);
  SDL_free(result->type);
  SDL_free(result->value);
  SDL_free(result->error);
  anvil_worker_treesitter_index_result_free(result->treesitter_index_result);
  anvil_ts_project_snapshot_release(result->project_snapshot);
  SDL_free(result);
}

AnvilWorkerTreeSitterIndexResult *anvil_worker_result_steal_treesitter_index_result(AnvilWorkerResult *result) {
  if (!result) return NULL;
  AnvilWorkerTreeSitterIndexResult *out = result->treesitter_index_result;
  result->treesitter_index_result = NULL;
  return out;
}

AnvilTSProjectSnapshot *anvil_worker_result_steal_project_snapshot(AnvilWorkerResult *result) {
  if (!result) return NULL;
  AnvilTSProjectSnapshot *out = result->project_snapshot;
  result->project_snapshot = NULL;
  return out;
}

uint64_t anvil_worker_job_id(const AnvilWorkerJob *job) { return job ? job->id : 0; }
const char *anvil_worker_job_kind(const AnvilWorkerJob *job) { return job && job->kind ? job->kind : ""; }
bool anvil_worker_job_cancel_requested(const AnvilWorkerJob *job) { return job_cancelled(job); }

const char *anvil_worker_job_status_string(const AnvilWorkerJob *job) {
  switch (job ? SDL_GetAtomicInt((SDL_AtomicInt *)&job->status) : -1) {
    case ANVIL_WORKER_STATUS_QUEUED: return "queued";
    case ANVIL_WORKER_STATUS_RUNNING: return "running";
    case ANVIL_WORKER_STATUS_COMPLETE: return "complete";
    case ANVIL_WORKER_STATUS_CANCELLED: return "cancelled";
    case ANVIL_WORKER_STATUS_FAILED: return "failed";
    default: return "unknown";
  }
}

uint64_t anvil_worker_result_job_id(const AnvilWorkerResult *result) { return result ? result->job_id : 0; }
const char *anvil_worker_result_kind(const AnvilWorkerResult *result) { return result && result->kind ? result->kind : ""; }
const char *anvil_worker_result_type(const AnvilWorkerResult *result) { return result && result->type ? result->type : ""; }
const char *anvil_worker_result_value(const AnvilWorkerResult *result) { return result && result->value ? result->value : NULL; }
const char *anvil_worker_result_error(const AnvilWorkerResult *result) { return result && result->error ? result->error : NULL; }
int anvil_worker_result_index(const AnvilWorkerResult *result) { return result ? result->index : 0; }
bool anvil_worker_result_cancelled(const AnvilWorkerResult *result) { return result ? result->cancelled : false; }
uint32_t anvil_worker_result_files_completed(const AnvilWorkerResult *result) { return result ? result->files_completed : 0; }
uint32_t anvil_worker_result_files_skipped(const AnvilWorkerResult *result) { return result ? result->files_skipped : 0; }
uint32_t anvil_worker_result_files_reused(const AnvilWorkerResult *result) { return result ? result->files_reused : 0; }
uint32_t anvil_worker_result_symbols_found(const AnvilWorkerResult *result) { return result ? result->symbols_found : 0; }
uint32_t anvil_worker_result_usages_found(const AnvilWorkerResult *result) { return result ? result->usages_found : 0; }
double anvil_worker_result_batch_total_ms(const AnvilWorkerResult *result) { return result ? result->batch_total_ms : 0.0; }
double anvil_worker_result_batch_parse_ms(const AnvilWorkerResult *result) { return result ? result->batch_parse_ms : 0.0; }
double anvil_worker_result_batch_project_record_ms(const AnvilWorkerResult *result) { return result ? result->batch_project_record_ms : 0.0; }
double anvil_worker_result_project_builder_ms(const AnvilWorkerResult *result) { return result ? result->project_builder_ms : 0.0; }
double anvil_worker_result_project_snapshot_ms(const AnvilWorkerResult *result) { return result ? result->project_snapshot_ms : 0.0; }

uint64_t anvil_worker_pool_submitted_count(const AnvilWorkerPool *pool) {
  if (!pool) return 0;
  if (!pool->queue_mutex) return pool->submitted;
  SDL_LockMutex(pool->queue_mutex);
  uint64_t value = pool->submitted;
  SDL_UnlockMutex(pool->queue_mutex);
  return value;
}

uint64_t anvil_worker_pool_completed_count(const AnvilWorkerPool *pool) {
  if (!pool) return 0;
  if (!pool->result_mutex) return pool->completed;
  SDL_LockMutex(pool->result_mutex);
  uint64_t value = pool->completed;
  SDL_UnlockMutex(pool->result_mutex);
  return value;
}

uint64_t anvil_worker_pool_cancelled_count(const AnvilWorkerPool *pool) {
  if (!pool) return 0;
  if (!pool->result_mutex) return pool->cancelled;
  SDL_LockMutex(pool->result_mutex);
  uint64_t value = pool->cancelled;
  SDL_UnlockMutex(pool->result_mutex);
  return value;
}

uint64_t anvil_worker_pool_failed_count(const AnvilWorkerPool *pool) {
  if (!pool) return 0;
  if (!pool->result_mutex) return pool->failed;
  SDL_LockMutex(pool->result_mutex);
  uint64_t value = pool->failed;
  SDL_UnlockMutex(pool->result_mutex);
  return value;
}

uint64_t anvil_worker_pool_result_count(const AnvilWorkerPool *pool) {
  if (!pool) return 0;
  if (!pool->result_mutex) return pool->result_count;
  SDL_LockMutex(pool->result_mutex);
  uint64_t value = pool->result_count;
  SDL_UnlockMutex(pool->result_mutex);
  return value;
}

int anvil_worker_pool_worker_count(const AnvilWorkerPool *pool) { return pool ? pool->worker_count : 0; }
