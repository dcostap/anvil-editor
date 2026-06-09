#include "thread_pool.h"

#include <SDL3/SDL.h>

#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { \
  if (!(expr)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); \
    return 1; \
  } \
} while (0)

typedef struct SumPayload {
  int a;
  int b;
} SumPayload;

static void free_ptr(void *ptr) {
  free(ptr);
}

static void *sum_task(void *ptr, SDL_AtomicInt *cancelled) {
  SumPayload *payload = (SumPayload *) ptr;
  if (SDL_GetAtomicInt(cancelled)) return NULL;
  int *result = (int *) malloc(sizeof(int));
  if (!result) return NULL;
  *result = payload->a + payload->b;
  return result;
}

static int test_background_task_returns_result(void) {
  CHECK(anvil_thread_pool_startup(2));
  CHECK(anvil_thread_pool_worker_count(anvil_system_thread_pool()) >= 2);

  SumPayload *payload = (SumPayload *) calloc(1, sizeof(SumPayload));
  CHECK(payload != NULL);
  payload->a = 17;
  payload->b = 25;

  AnvilTask *task = anvil_thread_pool_submit(
    anvil_system_thread_pool(),
    "test-sum",
    sum_task,
    payload,
    free_ptr,
    free_ptr
  );
  CHECK(task != NULL);

  AnvilTaskResult result = {0};
  for (int i = 0; i < 200; ++i) {
    result = anvil_task_result_if_complete(task);
    if (result.complete) break;
    SDL_Delay(1);
  }
  CHECK(result.complete);
  CHECK(result.result != NULL);
  CHECK(*(int *) result.result == 42);
  free(result.result);

  anvil_thread_pool_shutdown();
  return 0;
}

int main(void) {
  if (!SDL_Init(SDL_INIT_EVENTS)) {
    fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
    return 1;
  }
  int rc = test_background_task_returns_result();
  anvil_thread_pool_shutdown();
  SDL_Quit();
  return rc;
}
