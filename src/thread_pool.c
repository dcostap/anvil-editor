#include "thread_pool.h"

#include <SDL3/SDL.h>

#include <stdlib.h>
#include <string.h>

struct AnvilTask {
  SDL_AtomicInt refcount;
  SDL_AtomicInt cancelled;
  AnvilTaskFn fn;
  AnvilTaskFreeFn free_payload;
  AnvilTaskFreeFn free_result;
  void *payload;
  void *result;
  uint64_t start_ms;
  uint64_t end_ms;
  bool complete;
  struct AnvilTask *next;
};

struct AnvilThreadPool {
  SDL_Mutex *mutex;
  SDL_Condition *condition;
  SDL_Thread **workers;
  size_t worker_count;
  AnvilTask *queue_first;
  AnvilTask *queue_last;
  bool stopping;
};

static AnvilThreadPool system_pool;
static bool system_pool_started = false;

static uint64_t ticks_ms(void) {
  return SDL_GetTicksNS() / 1000000ull;
}

static void task_destroy(AnvilTask *task) {
  if (!task) return;
  if (task->free_payload && task->payload) task->free_payload(task->payload);
  if (task->free_result && task->result) task->free_result(task->result);
  free(task);
}

static void task_unref(AnvilTask *task) {
  if (!task) return;
  if (SDL_AtomicDecRef(&task->refcount)) task_destroy(task);
}

static AnvilTask *pool_pop_task(AnvilThreadPool *pool) {
  AnvilTask *task = pool->queue_first;
  if (!task) return NULL;
  pool->queue_first = task->next;
  if (!pool->queue_first) pool->queue_last = NULL;
  task->next = NULL;
  return task;
}

static int SDLCALL worker_main(void *data) {
  AnvilThreadPool *pool = (AnvilThreadPool *) data;
  for (;;) {
    SDL_LockMutex(pool->mutex);
    while (!pool->stopping && !pool->queue_first) {
      SDL_WaitCondition(pool->condition, pool->mutex);
    }
    if (pool->stopping && !pool->queue_first) {
      SDL_UnlockMutex(pool->mutex);
      break;
    }
    AnvilTask *task = pool_pop_task(pool);
    SDL_UnlockMutex(pool->mutex);

    if (task) {
      task->start_ms = ticks_ms();
      if (!SDL_GetAtomicInt(&task->cancelled) && task->fn) {
        task->result = task->fn(task->payload, &task->cancelled);
      }
      if (task->free_payload && task->payload) {
        task->free_payload(task->payload);
        task->payload = NULL;
      }
      task->end_ms = ticks_ms();
      SDL_LockMutex(pool->mutex);
      task->complete = true;
      SDL_UnlockMutex(pool->mutex);
      task_unref(task);
    }
  }
  return 0;
}

bool anvil_thread_pool_startup(size_t worker_count) {
  if (system_pool_started) return true;
  memset(&system_pool, 0, sizeof(system_pool));

  if (worker_count == 0) {
    int logical = SDL_GetNumLogicalCPUCores();
    worker_count = logical > 0 ? (size_t) logical : 2;
  }
  if (worker_count < 2) worker_count = 2;

  system_pool.mutex = SDL_CreateMutex();
  system_pool.condition = SDL_CreateCondition();
  system_pool.workers = (SDL_Thread **) calloc(worker_count, sizeof(SDL_Thread *));
  if (!system_pool.mutex || !system_pool.condition || !system_pool.workers) {
    anvil_thread_pool_shutdown();
    return false;
  }
  system_pool.worker_count = worker_count;

  for (size_t i = 0; i < worker_count; ++i) {
    char name[64];
    SDL_snprintf(name, sizeof(name), "anvil-worker-%u", (unsigned) (i + 1));
    system_pool.workers[i] = SDL_CreateThread(worker_main, name, &system_pool);
    if (!system_pool.workers[i]) {
      anvil_thread_pool_shutdown();
      return false;
    }
  }

  system_pool_started = true;
  return true;
}

void anvil_thread_pool_shutdown(void) {
  if (system_pool.mutex) {
    SDL_LockMutex(system_pool.mutex);
    system_pool.stopping = true;
    for (AnvilTask *task = system_pool.queue_first; task; task = task->next) {
      SDL_SetAtomicInt(&task->cancelled, 1);
    }
    if (system_pool.condition) SDL_BroadcastCondition(system_pool.condition);
    SDL_UnlockMutex(system_pool.mutex);
  }

  if (system_pool.workers) {
    for (size_t i = 0; i < system_pool.worker_count; ++i) {
      if (system_pool.workers[i]) SDL_WaitThread(system_pool.workers[i], NULL);
    }
  }

  if (system_pool.mutex) SDL_LockMutex(system_pool.mutex);
  AnvilTask *task = system_pool.queue_first;
  system_pool.queue_first = NULL;
  system_pool.queue_last = NULL;
  if (system_pool.mutex) SDL_UnlockMutex(system_pool.mutex);
  while (task) {
    AnvilTask *next = task->next;
    task->next = NULL;
    task->complete = true;
    task_unref(task);
    task = next;
  }

  free(system_pool.workers);
  if (system_pool.condition) SDL_DestroyCondition(system_pool.condition);
  if (system_pool.mutex) SDL_DestroyMutex(system_pool.mutex);
  memset(&system_pool, 0, sizeof(system_pool));
  system_pool_started = false;
}

AnvilThreadPool *anvil_system_thread_pool(void) {
  return system_pool_started ? &system_pool : NULL;
}

size_t anvil_thread_pool_worker_count(const AnvilThreadPool *pool) {
  return pool ? pool->worker_count : 0;
}

AnvilTask *anvil_thread_pool_submit(
  AnvilThreadPool *pool,
  const char *name,
  AnvilTaskFn fn,
  void *payload,
  AnvilTaskFreeFn free_payload,
  AnvilTaskFreeFn free_result
) {
  (void) name;
  if (!pool || !fn) return NULL;
  AnvilTask *task = (AnvilTask *) calloc(1, sizeof(AnvilTask));
  if (!task) return NULL;
  SDL_SetAtomicInt(&task->refcount, 2);
  SDL_SetAtomicInt(&task->cancelled, 0);
  task->fn = fn;
  task->payload = payload;
  task->free_payload = free_payload;
  task->free_result = free_result;

  SDL_LockMutex(pool->mutex);
  if (pool->stopping) {
    SDL_UnlockMutex(pool->mutex);
    task_unref(task);
    task_unref(task);
    return NULL;
  }
  if (pool->queue_last) pool->queue_last->next = task;
  else pool->queue_first = task;
  pool->queue_last = task;
  SDL_SignalCondition(pool->condition);
  SDL_UnlockMutex(pool->mutex);
  return task;
}

void anvil_task_cancel(AnvilTask *task) {
  if (task) SDL_SetAtomicInt(&task->cancelled, 1);
}

void anvil_task_release(AnvilTask *task) {
  if (!task) return;
  anvil_task_cancel(task);
  task_unref(task);
}

AnvilTaskResult anvil_task_result_if_complete(AnvilTask *task) {
  AnvilTaskResult out;
  memset(&out, 0, sizeof(out));
  if (!task) return out;

  AnvilThreadPool *pool = anvil_system_thread_pool();
  if (pool && pool->mutex) SDL_LockMutex(pool->mutex);
  bool complete = task->complete;
  if (complete) {
    out.complete = true;
    out.being_cancelled = SDL_GetAtomicInt(&task->cancelled) != 0;
    out.result = task->result;
    out.duration_ms = task->end_ms >= task->start_ms ? task->end_ms - task->start_ms : 0;
    task->result = NULL;
  } else {
    out.being_cancelled = SDL_GetAtomicInt(&task->cancelled) != 0;
  }
  if (pool && pool->mutex) SDL_UnlockMutex(pool->mutex);

  if (complete) task_unref(task);
  return out;
}
