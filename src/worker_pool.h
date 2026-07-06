#ifndef ANVIL_WORKER_POOL_H
#define ANVIL_WORKER_POOL_H

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdint.h>

typedef struct AnvilWorkerPool AnvilWorkerPool;
typedef struct AnvilWorkerJob AnvilWorkerJob;
typedef struct AnvilWorkerResult AnvilWorkerResult;
typedef struct AnvilWorkerCancelToken AnvilWorkerCancelToken;
typedef struct AnvilWorkerTreeSitterIndexResult AnvilWorkerTreeSitterIndexResult;

typedef struct AnvilWorkerJobSpec {
  const char *kind;
  const char *value;
  int count;
  uint32_t sleep_ms;

  const char *path;
  const char *language;
  const char *text;
  const char *outline_query;
  const char *usage_query;
  const char *cancel_token;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;
} AnvilWorkerJobSpec;

AnvilWorkerPool *anvil_worker_pool_create(const char *name, int worker_count);
void anvil_worker_pool_destroy(AnvilWorkerPool *pool, bool cancel_running);

AnvilWorkerJob *anvil_worker_pool_submit(AnvilWorkerPool *pool, const AnvilWorkerJobSpec *spec, char **error);
void anvil_worker_job_retain(AnvilWorkerJob *job);
void anvil_worker_job_release(AnvilWorkerJob *job);
bool anvil_worker_pool_cancel(AnvilWorkerPool *pool, AnvilWorkerJob *job);

uint64_t anvil_worker_job_id(const AnvilWorkerJob *job);
const char *anvil_worker_job_kind(const AnvilWorkerJob *job);
const char *anvil_worker_job_status_string(const AnvilWorkerJob *job);
bool anvil_worker_job_cancel_requested(const AnvilWorkerJob *job);

AnvilWorkerResult *anvil_worker_pool_pop_result(AnvilWorkerPool *pool);
void anvil_worker_result_free(AnvilWorkerResult *result);

uint64_t anvil_worker_result_job_id(const AnvilWorkerResult *result);
const char *anvil_worker_result_kind(const AnvilWorkerResult *result);
const char *anvil_worker_result_type(const AnvilWorkerResult *result);
const char *anvil_worker_result_value(const AnvilWorkerResult *result);
const char *anvil_worker_result_error(const AnvilWorkerResult *result);
int anvil_worker_result_index(const AnvilWorkerResult *result);
bool anvil_worker_result_cancelled(const AnvilWorkerResult *result);
AnvilWorkerTreeSitterIndexResult *anvil_worker_result_steal_treesitter_index_result(AnvilWorkerResult *result);

void anvil_worker_treesitter_index_result_free(AnvilWorkerTreeSitterIndexResult *result);
const char *anvil_worker_treesitter_index_result_language(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_byte_len(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_capture_count(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
const char *anvil_worker_treesitter_index_result_status(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
const char *anvil_worker_treesitter_index_result_error(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
bool anvil_worker_treesitter_index_result_exceeded_match_limit(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
uint64_t anvil_worker_treesitter_index_result_parse_ms(const AnvilWorkerTreeSitterIndexResult *result);
uint64_t anvil_worker_treesitter_index_result_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
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
);

uint64_t anvil_worker_pool_submitted_count(const AnvilWorkerPool *pool);
uint64_t anvil_worker_pool_completed_count(const AnvilWorkerPool *pool);
uint64_t anvil_worker_pool_cancelled_count(const AnvilWorkerPool *pool);
uint64_t anvil_worker_pool_failed_count(const AnvilWorkerPool *pool);
uint64_t anvil_worker_pool_result_count(const AnvilWorkerPool *pool);
int anvil_worker_pool_worker_count(const AnvilWorkerPool *pool);

AnvilWorkerCancelToken *anvil_worker_cancel_token_create(const char *name);
AnvilWorkerCancelToken *anvil_worker_cancel_token_open(const char *name);
void anvil_worker_cancel_token_retain(AnvilWorkerCancelToken *token);
void anvil_worker_cancel_token_release(AnvilWorkerCancelToken *token);
void anvil_worker_cancel_token_cancel(AnvilWorkerCancelToken *token);
bool anvil_worker_cancel_token_cancelled(const AnvilWorkerCancelToken *token);
const char *anvil_worker_cancel_token_name(const AnvilWorkerCancelToken *token);

#endif
