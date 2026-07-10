#include "worker_pool.h"

#include "markdown_parser.h"
#include "treesitter/languages.h"
#include "treesitter/service.h"
#include "treesitter/snapshot.h"

#include <tree_sitter/api.h>

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
  char *language;
  char *text;
  char *outline_query;
  char *usage_query;
  char *cancel_token;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;

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
  AnvilWorkerTreeSitterIndexResult *treesitter_index_result;
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
} AnvilWorkerTreeSitterCapture;

typedef struct AnvilWorkerTreeSitterQueryResult {
  AnvilWorkerTreeSitterCapture *captures;
  uint32_t count;
  uint32_t capacity;
  uint64_t query_ms;
  char *status;
  char *error;
  bool exceeded_match_limit;
} AnvilWorkerTreeSitterQueryResult;

struct AnvilWorkerTreeSitterIndexResult {
  char *language;
  uint32_t byte_len;
  uint64_t parse_ms;
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

struct AnvilWorkerPool {
  char *name;
  int worker_count;
  SDL_Thread **workers;
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
};

static char *pool_strdup(const char *s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char *copy = (char *)SDL_malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, s, len + 1);
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
  SDL_free(job->language);
  SDL_free(job->text);
  SDL_free(job->outline_query);
  SDL_free(job->usage_query);
  SDL_free(job->cancel_token);
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
  memset(query, 0, sizeof(*query));
}

void anvil_worker_treesitter_index_result_free(AnvilWorkerTreeSitterIndexResult *result) {
  if (!result) return;
  SDL_free(result->language);
  treesitter_query_result_free(&result->outline);
  treesitter_query_result_free(&result->usage);
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

uint64_t anvil_worker_treesitter_index_result_parse_ms(const AnvilWorkerTreeSitterIndexResult *result) {
  return result ? result->parse_ms : 0;
}

uint64_t anvil_worker_treesitter_index_result_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind) {
  const AnvilWorkerTreeSitterQueryResult *query = treesitter_query_result_for_kind(result, kind);
  return query ? query->query_ms : 0;
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
  uint32_t *order
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
  return true;
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
  return job && SDL_GetAtomicInt((SDL_AtomicInt *)&job->cancel) != 0;
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

typedef struct AnvilWorkerTextLines {
  const char **lines;
  uint32_t *lengths;
  uint32_t count;
} AnvilWorkerTextLines;

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

static bool text_lines_from_text(const char *text, AnvilWorkerTextLines *out, char **error) {
  if (!out) return false;
  memset(out, 0, sizeof(*out));
  const char *source = text ? text : "";
  size_t len = strlen(source);
  uint32_t count = 0;
  if (len == 0) {
    count = 1;
  } else {
    count = 1;
    for (size_t i = 0; i < len; ++i) {
      if (source[i] == '\n' && i + 1 < len) count++;
    }
  }
  out->lines = (const char **)SDL_calloc(count, sizeof(char *));
  out->lengths = (uint32_t *)SDL_calloc(count, sizeof(uint32_t));
  if (!out->lines || !out->lengths) {
    SDL_free(out->lines);
    SDL_free(out->lengths);
    pool_set_error(error, "out of memory splitting Tree-sitter input lines");
    memset(out, 0, sizeof(*out));
    return false;
  }
  out->count = count;
  if (len == 0) {
    out->lines[0] = "\n";
    out->lengths[0] = 1;
    return true;
  }
  size_t start = 0;
  uint32_t line = 0;
  for (size_t i = 0; i < len; ++i) {
    if (source[i] == '\n') {
      out->lines[line] = source + start;
      out->lengths[line] = (uint32_t)(i - start + 1);
      line++;
      start = i + 1;
    }
  }
  if (start < len) {
    out->lines[line] = source + start;
    out->lengths[line] = (uint32_t)(len - start);
  }
  return true;
}

static void text_lines_free(AnvilWorkerTextLines *lines) {
  if (!lines) return;
  SDL_free(lines->lines);
  SDL_free(lines->lengths);
  memset(lines, 0, sizeof(*lines));
}

static char *read_file_text(const char *path, char **error) {
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
  if (raw_size < 0) {
    fclose(fp);
    pool_set_error(error, "failed to size Tree-sitter index file");
    return NULL;
  }
  if (fseek(fp, 0, SEEK_SET) != 0) {
    fclose(fp);
    pool_set_error(error, "failed to rewind Tree-sitter index file");
    return NULL;
  }
  char *text = (char *)SDL_malloc((size_t)raw_size + 1);
  if (!text) {
    fclose(fp);
    pool_set_error(error, "out of memory reading Tree-sitter index file");
    return NULL;
  }
  size_t read = fread(text, 1, (size_t)raw_size, fp);
  fclose(fp);
  if (read != (size_t)raw_size) {
    SDL_free(text);
    pool_set_error(error, "failed to read Tree-sitter index file");
    return NULL;
  }
  text[read] = '\0';
  return text;
}

static TSQuery *compile_treesitter_query(const AnvilTSLanguage *language, const char *kind, const char *source, char **error) {
  if (!source || !source[0]) return NULL;
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(anvil_ts_language_ptr(language), source, (uint32_t)strlen(source), &error_offset, &error_type);
  if (!query) {
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "Tree-sitter %s query error %d at byte %u", kind ? kind : "", (int)error_type, (unsigned)error_offset);
    pool_set_error(error, buffer);
  }
  return query;
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
  copy->order = capture->order;
  query->count++;
  return true;
}

static bool run_treesitter_index_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const AnvilTSLanguage *language,
  const char *field,
  const char *source,
  TSTree *tree,
  const AnvilTSSnapshot *snapshot,
  AnvilWorkerTSParseRun *run,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  char **fatal_error
) {
  AnvilWorkerTreeSitterQueryResult *query_result = treesitter_query_result_for_kind_mut(index_result, field);
  if (!query_result || !source || !source[0]) return true;
  char *compile_error = NULL;
  TSQuery *query = compile_treesitter_query(language, field, source, &compile_error);
  if (!query) {
    query_result->status = pool_strdup("failed");
    query_result->error = compile_error;
    return true;
  }
  uint64_t started = SDL_GetTicks();
  bool exceeded = false;
  char *query_error = NULL;
  bool ok = anvil_ts_query_captures_in_tree(
    tree,
    snapshot,
    query,
    0,
    snapshot->byte_len,
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
  query_result->exceeded_match_limit = exceeded;
  query_result->status = pool_strdup(ok ? (exceeded ? "limit" : "ready") : treesitter_query_status_from_error(query_error, exceeded));
  if (!ok && !query_error && !query_result->status) pool_set_error(fatal_error, "out of memory storing Tree-sitter query status");
  if (query_error) {
    query_result->error = pool_strdup(query_error);
    free(query_error);
  }
  ts_query_delete(query);
  return true;
}

static void run_treesitter_index_text(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  if (!job->language || !job->language[0]) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("Tree-sitter native index job requires language");
    enqueue_result(pool, result);
    return;
  }
  const AnvilTSLanguage *language = anvil_ts_language_by_id(job->language);
  if (!language || !anvil_ts_language_is_compatible(language)) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) {
      char buffer[256];
      snprintf(buffer, sizeof(buffer), "unknown or incompatible Tree-sitter language '%s'", job->language);
      result->error = pool_strdup(buffer);
    }
    enqueue_result(pool, result);
    return;
  }

  char *error = NULL;
  char *owned_text = job->text ? pool_strdup(job->text) : read_file_text(job->path, &error);
  if (!owned_text) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to read Tree-sitter input");
    enqueue_result(pool, result);
    return;
  }

  AnvilWorkerTextLines lines;
  if (!text_lines_from_text(owned_text, &lines, &error)) {
    SDL_free(owned_text);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to split Tree-sitter input");
    enqueue_result(pool, result);
    return;
  }

  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(lines.lines, lines.lengths, lines.count, &error);
  text_lines_free(&lines);
  SDL_free(owned_text);
  if (!snapshot) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) {
      result->error = error ? pool_strdup(error) : pool_strdup("failed to create Tree-sitter snapshot");
    }
    free(error);
    enqueue_result(pool, result);
    return;
  }

  AnvilWorkerCancelToken *cancel_token = job->cancel_token ? anvil_worker_cancel_token_open(job->cancel_token) : NULL;
  TSParser *parser = ts_parser_new();
  if (!parser || !ts_parser_set_language(parser, anvil_ts_language_ptr(language))) {
    if (parser) ts_parser_delete(parser);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("failed to initialize Tree-sitter parser");
    enqueue_result(pool, result);
    return;
  }

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
  TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, parse_options);
  uint64_t parse_ms = SDL_GetTicks() - run.started_ticks;
  ts_parser_delete(parser);
  if (!tree) {
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    if (run.cancelled || job_cancelled(job)) {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
      enqueue_simple_result(pool, job, "cancelled");
    } else {
      SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
      AnvilWorkerResult *result = result_new(job, "error");
      if (result) result->error = pool_strdup(run.timed_out ? "Tree-sitter parse timed out" : "Tree-sitter parse failed");
      enqueue_result(pool, result);
    }
    return;
  }

  AnvilWorkerTreeSitterIndexResult *index_result = (AnvilWorkerTreeSitterIndexResult *)SDL_calloc(1, sizeof(*index_result));
  if (!index_result) {
    ts_tree_delete(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("out of memory allocating Tree-sitter index result");
    enqueue_result(pool, result);
    return;
  }
  index_result->language = pool_strdup(language->id);
  index_result->byte_len = snapshot->byte_len;
  index_result->parse_ms = parse_ms;
  if (!index_result->language) {
    anvil_worker_treesitter_index_result_free(index_result);
    ts_tree_delete(tree);
    anvil_worker_cancel_token_release(cancel_token);
    anvil_ts_snapshot_free(snapshot);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = pool_strdup("out of memory storing Tree-sitter index result");
    enqueue_result(pool, result);
    return;
  }

  bool have_fatal_error = false;
  char *fatal_error = NULL;
  if (job->outline_query) {
    run_treesitter_index_query(index_result, language, "outline", job->outline_query, tree, snapshot, &run, job->match_limit ? job->match_limit : 50000, job->max_captures ? job->max_captures : 50000, job->query_timeout_ms ? job->query_timeout_ms : 20, &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  if (!have_fatal_error && job->usage_query) {
    run_treesitter_index_query(index_result, language, "usage", job->usage_query, tree, snapshot, &run, job->usage_match_limit ? job->usage_match_limit : (job->match_limit ? job->match_limit : 50000), job->usage_max_captures ? job->usage_max_captures : (job->max_captures ? job->max_captures : 50000), job->usage_query_timeout_ms ? job->usage_query_timeout_ms : (job->query_timeout_ms ? job->query_timeout_ms : 20), &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  ts_tree_delete(tree);
  anvil_worker_cancel_token_release(cancel_token);
  anvil_ts_snapshot_free(snapshot);

  if (job_cancelled(job) || strcmp(anvil_worker_treesitter_index_result_status(index_result, "outline"), "cancelled") == 0 || strcmp(anvil_worker_treesitter_index_result_status(index_result, "usage"), "cancelled") == 0) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_free(fatal_error);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    return;
  }
  if (have_fatal_error) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = fatal_error ? fatal_error : pool_strdup("Tree-sitter native indexing failed");
    enqueue_result(pool, result);
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

static bool run_markdown_inline_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const char *source,
  AnvilMarkdownTree *tree,
  AnvilWorkerTSParseRun *run,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms
) {
  AnvilWorkerTreeSitterQueryResult *query_result = &index_result->usage;
  if (!source || !source[0]) return true;
  const AnvilTSLanguage *language = anvil_ts_language_by_id("markdown_inline");
  char *compile_error = NULL;
  TSQuery *query = compile_treesitter_query(language, "inline", source, &compile_error);
  if (!query) {
    query_result->status = pool_strdup("failed");
    query_result->error = compile_error;
    return true;
  }

  uint64_t started = SDL_GetTicks();
  bool ok = true;
  bool exceeded_any = false;
  uint32_t inline_count = anvil_markdown_tree_inline_count(tree);
  for (uint32_t i = 0; i < inline_count; i++) {
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
    ok = anvil_ts_query_captures_in_tree(
      anvil_markdown_tree_inline_tree(tree, i),
      anvil_markdown_tree_snapshot(tree),
      query,
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
  ts_query_delete(query);
  return true;
}

static void run_markdown_parse(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  char *error = NULL;
  char *owned_text = job->text ? pool_strdup(job->text) : read_file_text(job->path, &error);
  if (!owned_text) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to read Markdown input");
    enqueue_result(pool, result);
    return;
  }

  AnvilWorkerTextLines lines;
  if (!text_lines_from_text(owned_text, &lines, &error)) {
    SDL_free(owned_text);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? error : pool_strdup("failed to split Markdown input");
    enqueue_result(pool, result);
    return;
  }
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(lines.lines, lines.lengths, lines.count, &error);
  text_lines_free(&lines);
  SDL_free(owned_text);
  if (!snapshot) {
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = error ? pool_strdup(error) : pool_strdup("failed to create Markdown snapshot");
    free(error);
    enqueue_result(pool, result);
    return;
  }

  AnvilWorkerCancelToken *cancel_token = job->cancel_token ? anvil_worker_cancel_token_open(job->cancel_token) : NULL;
  AnvilWorkerTSParseRun run;
  memset(&run, 0, sizeof(run));
  run.started_ticks = SDL_GetTicks();
  run.timeout_ms = job->parse_timeout_ms ? job->parse_timeout_ms : 750;
  run.job = job;
  run.cancel_token = cancel_token;
  AnvilMarkdownTree *tree = anvil_markdown_tree_parse(
    snapshot,
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
  index_result->language = pool_strdup("markdown");
  index_result->byte_len = snapshot->byte_len;
  index_result->parse_ms = parse_ms;
  if (!index_result->language) {
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
  char *fatal_error = NULL;
  if (job->outline_query) {
    run_treesitter_index_query(
      index_result,
      block_language,
      "outline",
      job->outline_query,
      anvil_markdown_tree_block_tree(tree),
      snapshot,
      &run,
      job->match_limit ? job->match_limit : 50000,
      job->max_captures ? job->max_captures : 50000,
      job->query_timeout_ms ? job->query_timeout_ms : 20,
      &fatal_error
    );
  }
  if (!fatal_error && job->usage_query) {
    run_markdown_inline_query(
      index_result,
      job->usage_query,
      tree,
      &run,
      job->usage_match_limit ? job->usage_match_limit : (job->match_limit ? job->match_limit : 50000),
      job->usage_max_captures ? job->usage_max_captures : (job->max_captures ? job->max_captures : 50000),
      job->usage_query_timeout_ms ? job->usage_query_timeout_ms : (job->query_timeout_ms ? job->query_timeout_ms : 20)
    );
  }

  bool token_cancelled = anvil_worker_cancel_token_cancelled(cancel_token);
  anvil_markdown_tree_free(tree);
  anvil_worker_cancel_token_release(cancel_token);
  anvil_ts_snapshot_free(snapshot);
  bool cancelled = job_cancelled(job) || token_cancelled ||
    strcmp(anvil_worker_treesitter_index_result_status(index_result, "outline"), "cancelled") == 0 ||
    strcmp(anvil_worker_treesitter_index_result_status(index_result, "usage"), "cancelled") == 0;
  if (cancelled) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_free(fatal_error);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_CANCELLED);
    enqueue_simple_result(pool, job, "cancelled");
    return;
  }
  if (fatal_error) {
    anvil_worker_treesitter_index_result_free(index_result);
    SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_FAILED);
    AnvilWorkerResult *result = result_new(job, "error");
    if (result) result->error = fatal_error;
    enqueue_result(pool, result);
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

static void run_job(AnvilWorkerPool *pool, AnvilWorkerJob *job) {
  SDL_SetAtomicInt(&job->status, ANVIL_WORKER_STATUS_RUNNING);
  if (job_cancelled(job)) {
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
    run_treesitter_index_text(pool, job);
  } else if (strcmp(kind, "markdown_parse") == 0) {
    run_markdown_parse(pool, job);
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

static int worker_main(void *userdata) {
  AnvilWorkerPool *pool = (AnvilWorkerPool *)userdata;
  while (true) {
    SDL_LockMutex(pool->queue_mutex);
    while (!pool->terminate && pool->input_first == NULL) {
      SDL_WaitCondition(pool->queue_cond, pool->queue_mutex);
    }
    if (pool->terminate && pool->input_first == NULL) {
      SDL_UnlockMutex(pool->queue_mutex);
      return 0;
    }
    AnvilWorkerJob *job = pool->input_first;
    pool->input_first = job->next;
    if (!pool->input_first) pool->input_last = &pool->input_first;
    job->next = NULL;
    running_add_locked(pool, job);
    SDL_UnlockMutex(pool->queue_mutex);

    run_job(pool, job);
    int status = SDL_GetAtomicInt(&job->status);
    SDL_LockMutex(pool->result_mutex);
    if (status == ANVIL_WORKER_STATUS_COMPLETE) pool->completed++;
    else if (status == ANVIL_WORKER_STATUS_CANCELLED) pool->cancelled++;
    else if (status == ANVIL_WORKER_STATUS_FAILED) pool->failed++;
    SDL_UnlockMutex(pool->result_mutex);
    SDL_LockMutex(pool->queue_mutex);
    running_remove_locked(pool, job);
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
  if (!pool->name || !pool->queue_mutex || !pool->queue_cond || !pool->result_mutex || !pool->workers) {
    anvil_worker_pool_destroy(pool, true);
    return NULL;
  }
  for (int i = 0; i < worker_count; ++i) {
    char thread_name[64];
    snprintf(thread_name, sizeof(thread_name), "anvil-worker-%d", i + 1);
    pool->workers[i] = SDL_CreateThread(worker_main, thread_name, pool);
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
  SDL_free(pool->name);
  SDL_free(pool);
}

AnvilWorkerJob *anvil_worker_pool_submit(AnvilWorkerPool *pool, const AnvilWorkerJobSpec *spec, char **error) {
  if (error) *error = NULL;
  if (!pool || !spec || !spec->kind || !spec->kind[0]) {
    pool_set_error(error, "invalid worker job spec");
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
  job->language = pool_strdup(spec->language);
  job->text = pool_strdup(spec->text);
  job->outline_query = pool_strdup(spec->outline_query);
  job->usage_query = pool_strdup(spec->usage_query);
  job->cancel_token = pool_strdup(spec->cancel_token);
  job->parse_timeout_ms = spec->parse_timeout_ms;
  job->query_timeout_ms = spec->query_timeout_ms;
  job->match_limit = spec->match_limit;
  job->max_captures = spec->max_captures;
  job->usage_query_timeout_ms = spec->usage_query_timeout_ms;
  job->usage_match_limit = spec->usage_match_limit;
  job->usage_max_captures = spec->usage_max_captures;
  if (!job->kind || (spec->value && !job->value) || (spec->path && !job->path) || (spec->language && !job->language) || (spec->text && !job->text) || (spec->outline_query && !job->outline_query) || (spec->usage_query && !job->usage_query) || (spec->cancel_token && !job->cancel_token)) {
    anvil_worker_job_release(job);
    anvil_worker_job_release(job);
    pool_set_error(error, "out of memory copying worker job spec");
    return NULL;
  }

  SDL_LockMutex(pool->queue_mutex);
  if (pool->terminate) {
    SDL_UnlockMutex(pool->queue_mutex);
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
  SDL_free(result);
}

AnvilWorkerTreeSitterIndexResult *anvil_worker_result_steal_treesitter_index_result(AnvilWorkerResult *result) {
  if (!result) return NULL;
  AnvilWorkerTreeSitterIndexResult *out = result->treesitter_index_result;
  result->treesitter_index_result = NULL;
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
