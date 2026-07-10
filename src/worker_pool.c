#include "worker_pool.h"

#include "markdown_parser.h"
#include "markdown_extensions.h"
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
  AnvilWorkerTreeSitterIndexResult *previous_result;

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
  uint64_t node_id;
} AnvilWorkerTreeSitterCapture;

typedef struct AnvilWorkerTreeSitterQueryResult {
  AnvilWorkerTreeSitterCapture *captures;
  uint32_t count;
  uint32_t capacity;
  uint64_t query_ms;
  char *status;
  char *error;
  bool exceeded_match_limit;
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
  bool incremental;
  bool outline_query_reusable;
  uint32_t reused_block_capture_count;
  uint32_t reused_inline_count;
  AnvilMarkdownTree *markdown_tree;
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
  anvil_worker_treesitter_index_result_free(job->previous_result);
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
  TSTree *tree,
  const AnvilTSSnapshot *snapshot,
  uint32_t byte_start,
  uint32_t byte_end,
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
  uint64_t job_started = SDL_GetTicks();
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
  SDL_SetAtomicInt(&index_result->refcount, 1);
  index_result->language = pool_strdup(language->id);
  index_result->byte_len = snapshot->byte_len;
  index_result->line_count = snapshot->line_count;
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
    run_treesitter_index_query(index_result, language, "outline", job->outline_query, tree, snapshot, 0, snapshot->byte_len, &run, job->match_limit ? job->match_limit : 50000, job->max_captures ? job->max_captures : 50000, job->query_timeout_ms ? job->query_timeout_ms : 20, &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  if (!have_fatal_error && job->usage_query) {
    run_treesitter_index_query(index_result, language, "usage", job->usage_query, tree, snapshot, 0, snapshot->byte_len, &run, job->usage_match_limit ? job->usage_match_limit : (job->match_limit ? job->match_limit : 50000), job->usage_max_captures ? job->usage_max_captures : (job->max_captures ? job->max_captures : 50000), job->usage_query_timeout_ms ? job->usage_query_timeout_ms : (job->query_timeout_ms ? job->query_timeout_ms : 20), &fatal_error);
    have_fatal_error = fatal_error != NULL;
  }
  build_query_line_index(&index_result->outline);
  build_query_line_index(&index_result->usage);
  index_result->total_ms = SDL_GetTicks() - job_started;
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
  AnvilMarkdownTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
  AnvilWorkerTSParseRun *run,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  char **fatal_error
) {
  uint32_t changed_count = edit ? anvil_markdown_tree_changed_range_count(tree) : 0;
  if (!previous_result || !edit) {
    return run_treesitter_index_query(
      index_result, language, "outline", source, anvil_markdown_tree_block_tree(tree),
      snapshot, 0, snapshot->byte_len, run, match_limit, max_captures, timeout_ms, fatal_error
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
    index_result, language, "outline", source, anvil_markdown_tree_block_tree(tree),
    snapshot, changed_start, changed_end, run, match_limit, max_captures,
    timeout_ms, fatal_error
  );
}

static bool run_markdown_inline_query(
  AnvilWorkerTreeSitterIndexResult *index_result,
  const AnvilWorkerTreeSitterIndexResult *previous_result,
  const char *source,
  AnvilMarkdownTree *tree,
  const AnvilTSSnapshot *snapshot,
  const TSInputEdit *edit,
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
  uint64_t job_started = SDL_GetTicks();
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
      tree,
      snapshot,
      have_identity_edit ? &identity_edit : NULL,
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
      inline_previous,
      job->usage_query,
      tree,
      snapshot,
      have_identity_edit ? &identity_edit : NULL,
      &run,
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
  build_query_line_index(&index_result->outline);
  build_query_line_index(&index_result->usage);
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
  job->previous_result = spec->previous_result;
  anvil_worker_treesitter_index_result_retain(job->previous_result);
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
