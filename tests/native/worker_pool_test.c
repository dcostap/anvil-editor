#include "worker_pool.h"

#include <SDL3/SDL.h>

#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)

static int drain_until_type(AnvilWorkerPool *pool, uint64_t job_id, const char *type, int timeout_ms) {
  Uint64 start = SDL_GetTicks();
  while ((int)(SDL_GetTicks() - start) < timeout_ms) {
    AnvilWorkerResult *result = NULL;
    while ((result = anvil_worker_pool_pop_result(pool)) != NULL) {
      int matched = anvil_worker_result_job_id(result) == job_id && strcmp(anvil_worker_result_type(result), type) == 0;
      anvil_worker_result_free(result);
      if (matched) return 1;
    }
    SDL_Delay(1);
  }
  return 0;
}

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;
  CHECK(SDL_Init(0));

  AnvilWorkerPool *pool = anvil_worker_pool_create("native-test", 2);
  CHECK(pool != NULL);
  CHECK(anvil_worker_pool_worker_count(pool) == 2);

  char *error = NULL;
  AnvilWorkerJobSpec echo = { "test_echo", "hello", 0, 0 };
  AnvilWorkerJob *echo_job = anvil_worker_pool_submit(pool, &echo, &error);
  CHECK(echo_job != NULL);
  CHECK(error == NULL);
  uint64_t echo_id = anvil_worker_job_id(echo_job);
  CHECK(echo_id != 0);
  CHECK(drain_until_type(pool, echo_id, "final", 1000));
  CHECK(strcmp(anvil_worker_job_status_string(echo_job), "complete") == 0);
  anvil_worker_job_release(echo_job);

  AnvilWorkerJobSpec count = { "test_count", NULL, 1000, 1 };
  AnvilWorkerJob *count_job = anvil_worker_pool_submit(pool, &count, &error);
  CHECK(count_job != NULL);
  uint64_t count_id = anvil_worker_job_id(count_job);
  int saw_progress = 0;
  Uint64 start = SDL_GetTicks();
  while ((int)(SDL_GetTicks() - start) < 1000 && !saw_progress) {
    AnvilWorkerResult *result = anvil_worker_pool_pop_result(pool);
    if (result) {
      if (anvil_worker_result_job_id(result) == count_id && strcmp(anvil_worker_result_type(result), "progress") == 0) saw_progress = 1;
      anvil_worker_result_free(result);
    } else {
      SDL_Delay(1);
    }
  }
  CHECK(saw_progress);
  CHECK(anvil_worker_pool_cancel(pool, count_job));
  CHECK(drain_until_type(pool, count_id, "cancelled", 1000));
  CHECK(strcmp(anvil_worker_job_status_string(count_job), "cancelled") == 0);
  anvil_worker_job_release(count_job);

  AnvilWorkerJobSpec fail = { "test_fail", "boom", 0, 0 };
  AnvilWorkerJob *fail_job = anvil_worker_pool_submit(pool, &fail, &error);
  CHECK(fail_job != NULL);
  CHECK(drain_until_type(pool, anvil_worker_job_id(fail_job), "error", 1000));
  CHECK(strcmp(anvil_worker_job_status_string(fail_job), "failed") == 0);
  anvil_worker_job_release(fail_job);

  CHECK(anvil_worker_pool_submitted_count(pool) == 3);
  CHECK(anvil_worker_pool_completed_count(pool) >= 1);
  CHECK(anvil_worker_pool_cancelled_count(pool) >= 1);
  CHECK(anvil_worker_pool_failed_count(pool) >= 1);

  anvil_worker_pool_destroy(pool, true);
  SDL_Quit();
  return 0;
}
