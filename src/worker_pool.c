#include "worker_pool.h"

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
  struct AnvilWorkerResult *next;
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
  if (!job->kind || (spec->value && !job->value)) {
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
  SDL_free(result);
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
