#ifndef ANVIL_THREAD_POOL_H
#define ANVIL_THREAD_POOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <SDL3/SDL_atomic.h>

typedef struct AnvilThreadPool AnvilThreadPool;
typedef struct AnvilTask AnvilTask;

typedef void *(*AnvilTaskFn)(void *payload, SDL_AtomicInt *cancelled);
typedef void (*AnvilTaskFreeFn)(void *ptr);

typedef struct AnvilTaskResult {
  bool complete;
  bool being_cancelled;
  void *result;
  uint64_t duration_ms;
} AnvilTaskResult;

bool anvil_thread_pool_startup(size_t worker_count);
void anvil_thread_pool_shutdown(void);
AnvilThreadPool *anvil_system_thread_pool(void);
size_t anvil_thread_pool_worker_count(const AnvilThreadPool *pool);

AnvilTask *anvil_thread_pool_submit(
  AnvilThreadPool *pool,
  const char *name,
  AnvilTaskFn fn,
  void *payload,
  AnvilTaskFreeFn free_payload,
  AnvilTaskFreeFn free_result
);

void anvil_task_cancel(AnvilTask *task);
void anvil_task_release(AnvilTask *task);
AnvilTaskResult anvil_task_result_if_complete(AnvilTask *task);

#endif
