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

  AnvilWorkerJobSpec ts = { 0 };
  ts.kind = "treesitter_index_text";
  ts.language = "c";
  ts.text = "int add(int a, int b) { return a + b; }\n";
  ts.outline_query = "(function_definition) @definition.function";
  ts.parse_timeout_ms = 1000;
  ts.query_timeout_ms = 100;
  ts.max_captures = 100;
  AnvilWorkerJob *ts_job = anvil_worker_pool_submit(pool, &ts, &error);
  CHECK(ts_job != NULL);
  uint64_t ts_id = anvil_worker_job_id(ts_job);
  int saw_ts_result = 0;
  start = SDL_GetTicks();
  while ((int)(SDL_GetTicks() - start) < 1000 && !saw_ts_result) {
    AnvilWorkerResult *result = anvil_worker_pool_pop_result(pool);
    if (result) {
      if (anvil_worker_result_job_id(result) == ts_id && strcmp(anvil_worker_result_type(result), "result") == 0) {
        AnvilWorkerTreeSitterIndexResult *index_result = anvil_worker_result_steal_treesitter_index_result(result);
        CHECK(index_result != NULL);
        CHECK(strcmp(anvil_worker_treesitter_index_result_language(index_result), "c") == 0);
        CHECK(strcmp(anvil_worker_treesitter_index_result_status(index_result, "outline"), "ready") == 0);
        CHECK(anvil_worker_treesitter_index_result_capture_count(index_result, "outline") >= 1);
        const char *name = NULL;
        uint32_t name_len = 0;
        CHECK(anvil_worker_treesitter_index_result_capture_at(index_result, "outline", 0, &name, &name_len, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL));
        CHECK(name != NULL && name_len == strlen("definition.function") && strncmp(name, "definition.function", name_len) == 0);
        anvil_worker_treesitter_index_result_free(index_result);
        saw_ts_result = 1;
      }
      anvil_worker_result_free(result);
    } else {
      SDL_Delay(1);
    }
  }
  CHECK(saw_ts_result);
  CHECK(drain_until_type(pool, ts_id, "final", 1000));
  CHECK(strcmp(anvil_worker_job_status_string(ts_job), "complete") == 0);
  anvil_worker_job_release(ts_job);

  AnvilWorkerJobSpec markdown = { 0 };
  markdown.kind = "markdown_parse";
  markdown.text = "# Hello *world*.\n\nParagraph with **bold**.\n";
  markdown.outline_query = "(atx_heading) @heading";
  markdown.usage_query = "[(emphasis) (strong_emphasis)] @span";
  markdown.parse_timeout_ms = 1000;
  markdown.query_timeout_ms = 100;
  markdown.usage_query_timeout_ms = 100;
  markdown.max_captures = 100;
  markdown.usage_max_captures = 100;
  AnvilWorkerJob *markdown_job = anvil_worker_pool_submit(pool, &markdown, &error);
  CHECK(markdown_job != NULL);
  uint64_t markdown_id = anvil_worker_job_id(markdown_job);
  int saw_markdown_result = 0;
  start = SDL_GetTicks();
  while ((int)(SDL_GetTicks() - start) < 1000 && !saw_markdown_result) {
    AnvilWorkerResult *result = anvil_worker_pool_pop_result(pool);
    if (result) {
      if (anvil_worker_result_job_id(result) == markdown_id && strcmp(anvil_worker_result_type(result), "result") == 0) {
        AnvilWorkerTreeSitterIndexResult *parse_result = anvil_worker_result_steal_treesitter_index_result(result);
        CHECK(parse_result != NULL);
        CHECK(strcmp(anvil_worker_treesitter_index_result_language(parse_result), "markdown") == 0);
        CHECK(strcmp(anvil_worker_treesitter_index_result_status(parse_result, "outline"), "ready") == 0);
        CHECK(strcmp(anvil_worker_treesitter_index_result_status(parse_result, "usage"), "ready") == 0);
        CHECK(anvil_worker_treesitter_index_result_capture_count(parse_result, "outline") == 1);
        CHECK(anvil_worker_treesitter_index_result_capture_count(parse_result, "usage") == 2);
        anvil_worker_treesitter_index_result_free(parse_result);
        saw_markdown_result = 1;
      }
      anvil_worker_result_free(result);
    } else {
      SDL_Delay(1);
    }
  }
  CHECK(saw_markdown_result);
  CHECK(drain_until_type(pool, markdown_id, "final", 1000));
  CHECK(strcmp(anvil_worker_job_status_string(markdown_job), "complete") == 0);
  anvil_worker_job_release(markdown_job);

  CHECK(anvil_worker_pool_submitted_count(pool) == 5);
  CHECK(anvil_worker_pool_completed_count(pool) >= 1);
  CHECK(anvil_worker_pool_cancelled_count(pool) >= 1);
  CHECK(anvil_worker_pool_failed_count(pool) >= 1);

  anvil_worker_pool_destroy(pool, true);
  SDL_Quit();
  return 0;
}
