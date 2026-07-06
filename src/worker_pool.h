#ifndef ANVIL_WORKER_POOL_H
#define ANVIL_WORKER_POOL_H

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdint.h>

typedef struct AnvilWorkerPool AnvilWorkerPool;
typedef struct AnvilWorkerJob AnvilWorkerJob;
typedef struct AnvilWorkerResult AnvilWorkerResult;
typedef struct AnvilWorkerCancelToken AnvilWorkerCancelToken;

typedef struct AnvilWorkerJobSpec {
  const char *kind;
  const char *value;
  int count;
  uint32_t sleep_ms;
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
