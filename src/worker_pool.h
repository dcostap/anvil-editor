#ifndef ANVIL_WORKER_POOL_H
#define ANVIL_WORKER_POOL_H

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "treesitter/project_file.h"

typedef struct AnvilWorkerPool AnvilWorkerPool;
typedef struct AnvilWorkerJob AnvilWorkerJob;
typedef struct AnvilWorkerResult AnvilWorkerResult;
typedef struct AnvilWorkerCancelToken AnvilWorkerCancelToken;
typedef struct AnvilWorkerTreeSitterIndexResult AnvilWorkerTreeSitterIndexResult;

typedef enum AnvilWorkerTreeSitterResultCapability {
  ANVIL_WORKER_TS_CAPTURE_PAGING = 1u << 0,
  ANVIL_WORKER_TS_LINE_RANGE_LOOKUP = 1u << 1,
  ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS = 1u << 2,
} AnvilWorkerTreeSitterResultCapability;

typedef struct AnvilWorkerProjectBatchFileSpec {
  const char *path;
  const char *relpath;
  const char *fingerprint;
  const char *language;
  const char *outline_query;
  size_t outline_query_len;
  const char *usage_query;
  size_t usage_query_len;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;
  uint32_t max_file_bytes;
} AnvilWorkerProjectBatchFileSpec;

typedef struct AnvilWorkerProjectRunLanguageSpec {
  const char *id;
  const char *grammar;
  const char *const *file_patterns;
  uint32_t file_pattern_count;
  const char *outline_query;
  size_t outline_query_len;
  const char *usage_query;
  size_t usage_query_len;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;
} AnvilWorkerProjectRunLanguageSpec;

typedef struct AnvilWorkerJobSpec {
  const char *kind;
  const char *value;
  int count;
  uint32_t sleep_ms;

  const char *path;
  const char *relpath;
  const char *language;
  const char *text;
  size_t text_len;
  const char *outline_query;
  size_t outline_query_len;
  const char *usage_query;
  size_t usage_query_len;
  const char *cancel_token;
  uint32_t parse_timeout_ms;
  uint32_t query_timeout_ms;
  uint32_t match_limit;
  uint32_t max_captures;
  uint32_t usage_query_timeout_ms;
  uint32_t usage_match_limit;
  uint32_t usage_max_captures;
  uint32_t max_file_bytes;
  uint32_t result_capabilities;
  bool result_capabilities_set;
  AnvilWorkerTreeSitterIndexResult *previous_result;
  const AnvilWorkerProjectBatchFileSpec *project_files;
  uint32_t project_file_count;
  uint64_t project_builder_id;
  uint32_t project_usage_cap;
  const char *project_root;
  const char *const *project_scan_paths;
  uint32_t project_scan_path_count;
  const char *const *project_remove_paths;
  uint32_t project_remove_path_count;
  bool project_scoped;
  const char *const *project_excluded_paths;
  uint32_t project_excluded_path_count;
  const char *const *project_ignore_patterns;
  uint32_t project_ignore_pattern_count;
  const AnvilWorkerProjectRunLanguageSpec *project_languages;
  uint32_t project_language_count;
  uint32_t project_progress_files;
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
uint32_t anvil_worker_result_files_completed(const AnvilWorkerResult *result);
uint32_t anvil_worker_result_files_skipped(const AnvilWorkerResult *result);
uint32_t anvil_worker_result_files_reused(const AnvilWorkerResult *result);
uint32_t anvil_worker_result_symbols_found(const AnvilWorkerResult *result);
uint32_t anvil_worker_result_usages_found(const AnvilWorkerResult *result);
double anvil_worker_result_batch_total_ms(const AnvilWorkerResult *result);
double anvil_worker_result_batch_parse_ms(const AnvilWorkerResult *result);
double anvil_worker_result_batch_project_record_ms(const AnvilWorkerResult *result);
AnvilWorkerTreeSitterIndexResult *anvil_worker_result_steal_treesitter_index_result(AnvilWorkerResult *result);

void anvil_worker_treesitter_index_result_retain(AnvilWorkerTreeSitterIndexResult *result);
void anvil_worker_treesitter_index_result_free(AnvilWorkerTreeSitterIndexResult *result);
const char *anvil_worker_treesitter_index_result_language(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_byte_len(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_line_count(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_capture_count(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
const char *anvil_worker_treesitter_index_result_status(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
const char *anvil_worker_treesitter_index_result_error(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
bool anvil_worker_treesitter_index_result_exceeded_match_limit(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
bool anvil_worker_treesitter_index_result_line_indexed(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
uint64_t anvil_worker_treesitter_index_result_parse_ms(const AnvilWorkerTreeSitterIndexResult *result);
uint64_t anvil_worker_treesitter_index_result_block_parse_ms(const AnvilWorkerTreeSitterIndexResult *result);
uint64_t anvil_worker_treesitter_index_result_inline_parse_ms(const AnvilWorkerTreeSitterIndexResult *result);
uint64_t anvil_worker_treesitter_index_result_total_ms(const AnvilWorkerTreeSitterIndexResult *result);
double anvil_worker_treesitter_index_result_precise_total_ms(const AnvilWorkerTreeSitterIndexResult *result);
double anvil_worker_treesitter_index_result_prepare_input_ms(const AnvilWorkerTreeSitterIndexResult *result);
double anvil_worker_treesitter_index_result_parser_setup_ms(const AnvilWorkerTreeSitterIndexResult *result);
double anvil_worker_treesitter_index_result_precise_parse_ms(const AnvilWorkerTreeSitterIndexResult *result);
bool anvil_worker_treesitter_index_result_incremental(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_reused_block_capture_count(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_reused_inline_count(const AnvilWorkerTreeSitterIndexResult *result);
uint64_t anvil_worker_treesitter_index_result_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
double anvil_worker_treesitter_index_result_precise_query_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
double anvil_worker_treesitter_index_result_query_compile_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
double anvil_worker_treesitter_index_result_line_index_ms(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
double anvil_worker_treesitter_index_result_project_record_ms(const AnvilWorkerTreeSitterIndexResult *result);
bool anvil_worker_treesitter_index_result_query_cache_hit(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
bool anvil_worker_treesitter_index_result_query_cache_miss(const AnvilWorkerTreeSitterIndexResult *result, const char *kind);
bool anvil_worker_treesitter_index_result_parser_reused(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_capabilities(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_project_symbol_count(const AnvilWorkerTreeSitterIndexResult *result);
uint32_t anvil_worker_treesitter_index_result_project_usage_count(const AnvilWorkerTreeSitterIndexResult *result);
AnvilTSProjectFileResult *anvil_worker_treesitter_index_result_take_project_file(AnvilWorkerTreeSitterIndexResult *result);
const char *anvil_worker_treesitter_index_result_project_path(const AnvilWorkerTreeSitterIndexResult *result);
const char *anvil_worker_treesitter_index_result_project_relpath(const AnvilWorkerTreeSitterIndexResult *result);
bool anvil_worker_treesitter_index_result_project_symbol_at(const AnvilWorkerTreeSitterIndexResult *result, uint32_t index, AnvilTSProjectSymbolView *view);
bool anvil_worker_treesitter_index_result_project_usage_at(const AnvilWorkerTreeSitterIndexResult *result, uint32_t index, AnvilTSProjectUsageView *view);
uint32_t anvil_worker_treesitter_index_result_captures_for_lines(
  const AnvilWorkerTreeSitterIndexResult *result,
  const char *kind,
  uint32_t line1,
  uint32_t line2,
  uint32_t *indices,
  uint32_t capacity
);
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
