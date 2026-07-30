#include "api.h"
#include "../worker_pool.h"
#include "../treesitter/project_index.h"

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define PROJECT_RECORD_PAGE_LIMIT 4096u

#define API_TYPE_WORKER_POOL "NativeWorkerPool"
#define API_TYPE_WORKER_JOB "NativeWorkerJob"
#define API_TYPE_WORKER_CANCEL_TOKEN "NativeWorkerCancelToken"
#define API_TYPE_TREESITTER_INDEX_RESULT "NativeTreeSitterIndexResult"
#define API_TYPE_PROJECT_BUILDER "NativeTreeSitterProjectBuilder"
#define API_TYPE_PROJECT_SNAPSHOT "NativeTreeSitterProjectSnapshot"
#define API_TYPE_GIT_STATUS_SNAPSHOT "NativeFileTreeGitStatusSnapshot"
#define API_TYPE_PROJECT_FILE_MANIFEST "NativeProjectFileManifestSnapshot"
#define API_TYPE_MARKDOWN_VAULT_SNAPSHOT "NativeMarkdownVaultSnapshot"

typedef struct {
  AnvilWorkerPool *pool;
} LuaWorkerPool;

typedef struct {
  AnvilWorkerJob *job;
} LuaWorkerJob;

typedef struct {
  AnvilWorkerCancelToken *token;
} LuaWorkerCancelToken;

typedef struct {
  AnvilWorkerTreeSitterIndexResult *result;
} LuaTreeSitterIndexResult;

typedef struct {
  AnvilTSProjectBuilder *builder;
} LuaProjectBuilder;

typedef struct {
  AnvilTSProjectSnapshot *snapshot;
} LuaProjectSnapshot;

typedef struct {
  AnvilGitStatusSnapshot *snapshot;
} LuaGitStatusSnapshot;

typedef struct {
  AnvilProjectFileManifestSnapshot *snapshot;
} LuaProjectFileManifest;

typedef struct {
  AnvilMarkdownVaultSnapshot *snapshot;
} LuaMarkdownVaultSnapshot;

static LuaWorkerPool *check_pool(lua_State *L, int idx) {
  LuaWorkerPool *pool = (LuaWorkerPool *)luaL_checkudata(L, idx, API_TYPE_WORKER_POOL);
  luaL_argcheck(L, pool && pool->pool, idx, "closed native worker pool");
  return pool;
}

static LuaWorkerJob *check_job(lua_State *L, int idx) {
  LuaWorkerJob *job = (LuaWorkerJob *)luaL_checkudata(L, idx, API_TYPE_WORKER_JOB);
  luaL_argcheck(L, job && job->job, idx, "released native worker job");
  return job;
}

static LuaWorkerCancelToken *check_cancel_token(lua_State *L, int idx) {
  LuaWorkerCancelToken *token = (LuaWorkerCancelToken *)luaL_checkudata(L, idx, API_TYPE_WORKER_CANCEL_TOKEN);
  luaL_argcheck(L, token && token->token, idx, "released native worker cancel token");
  return token;
}

static LuaProjectBuilder *check_project_builder(lua_State *L, int idx) {
  LuaProjectBuilder *builder = (LuaProjectBuilder *)luaL_checkudata(L, idx, API_TYPE_PROJECT_BUILDER);
  luaL_argcheck(L, builder && builder->builder, idx, "closed native Project builder");
  return builder;
}

static LuaProjectSnapshot *check_project_snapshot(lua_State *L, int idx) {
  LuaProjectSnapshot *snapshot = (LuaProjectSnapshot *)luaL_checkudata(L, idx, API_TYPE_PROJECT_SNAPSHOT);
  luaL_argcheck(L, snapshot && snapshot->snapshot, idx, "closed native Project snapshot");
  return snapshot;
}

static LuaTreeSitterIndexResult *check_treesitter_index_result(lua_State *L, int idx) {
  LuaTreeSitterIndexResult *result = (LuaTreeSitterIndexResult *)luaL_checkudata(L, idx, API_TYPE_TREESITTER_INDEX_RESULT);
  luaL_argcheck(L, result && result->result, idx, "released native Tree-sitter index result");
  return result;
}

static LuaGitStatusSnapshot *check_git_status_snapshot(lua_State *L, int idx) {
  LuaGitStatusSnapshot *snapshot = (LuaGitStatusSnapshot *)luaL_checkudata(L, idx, API_TYPE_GIT_STATUS_SNAPSHOT);
  luaL_argcheck(L, snapshot && snapshot->snapshot, idx, "closed native File Tree Git status snapshot");
  return snapshot;
}

static LuaProjectFileManifest *check_project_file_manifest(lua_State *L, int idx) {
  LuaProjectFileManifest *manifest = (LuaProjectFileManifest *)luaL_checkudata(L, idx, API_TYPE_PROJECT_FILE_MANIFEST);
  luaL_argcheck(L, manifest && manifest->snapshot, idx, "closed native Project file manifest");
  return manifest;
}

static LuaMarkdownVaultSnapshot *check_markdown_vault_snapshot(lua_State *L, int idx) {
  LuaMarkdownVaultSnapshot *snapshot = (LuaMarkdownVaultSnapshot *)luaL_checkudata(L, idx, API_TYPE_MARKDOWN_VAULT_SNAPSHOT);
  luaL_argcheck(L, snapshot && snapshot->snapshot, idx, "closed native Markdown vault snapshot");
  return snapshot;
}

static int opt_int_field(lua_State *L, int table, const char *key, int def) {
  int out = def;
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) out = (int)luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  return out;
}

static uint32_t opt_uint32_field(lua_State *L, int table, const char *key, uint32_t def) {
  uint32_t out = def;
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) {
    lua_Integer raw = luaL_checkinteger(L, -1);
    luaL_argcheck(L, raw >= 0 && raw <= UINT32_MAX, table, "integer field out of uint32 range");
    out = (uint32_t)raw;
  }
  lua_pop(L, 1);
  return out;
}

static const char *opt_string_field(lua_State *L, int table, const char *key, const char *def) {
  const char *out = def;
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) out = luaL_checkstring(L, -1);
  lua_pop(L, 1);
  return out;
}

static const char *opt_lstring_field(lua_State *L, int table, const char *key, size_t *len) {
  const char *out = NULL;
  if (len) *len = 0;
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) out = luaL_checklstring(L, -1, len);
  lua_pop(L, 1);
  return out;
}

static bool opt_bool_field(lua_State *L, int table, const char *key, bool *present) {
  bool out = false;
  lua_getfield(L, table, key);
  if (!lua_isnil(L, -1)) {
    if (present) *present = true;
    out = lua_toboolean(L, -1) != 0;
  }
  lua_pop(L, 1);
  return out;
}

static int pool_gc(lua_State *L) {
  LuaWorkerPool *pool = (LuaWorkerPool *)luaL_checkudata(L, 1, API_TYPE_WORKER_POOL);
  if (pool && pool->pool) {
    anvil_worker_pool_destroy(pool->pool, true);
    pool->pool = NULL;
  }
  return 0;
}

static int job_gc(lua_State *L) {
  LuaWorkerJob *job = (LuaWorkerJob *)luaL_checkudata(L, 1, API_TYPE_WORKER_JOB);
  if (job && job->job) {
    anvil_worker_job_release(job->job);
    job->job = NULL;
  }
  return 0;
}

static int cancel_token_gc(lua_State *L) {
  LuaWorkerCancelToken *token = (LuaWorkerCancelToken *)luaL_checkudata(L, 1, API_TYPE_WORKER_CANCEL_TOKEN);
  if (token && token->token) {
    anvil_worker_cancel_token_release(token->token);
    token->token = NULL;
  }
  return 0;
}

static int treesitter_index_result_gc(lua_State *L) {
  LuaTreeSitterIndexResult *result = (LuaTreeSitterIndexResult *)luaL_checkudata(L, 1, API_TYPE_TREESITTER_INDEX_RESULT);
  if (result && result->result) {
    anvil_worker_treesitter_index_result_free(result->result);
    result->result = NULL;
  }
  return 0;
}

static int treesitter_index_result_close(lua_State *L) {
  LuaTreeSitterIndexResult *result = (LuaTreeSitterIndexResult *)luaL_checkudata(
    L, 1, API_TYPE_TREESITTER_INDEX_RESULT
  );
  bool released = result && result->result;
  if (released) {
    anvil_worker_treesitter_index_result_free(result->result);
    result->result = NULL;
  }
  lua_pushboolean(L, released);
  return 1;
}

static void push_job_handle(lua_State *L, AnvilWorkerJob *job) {
  LuaWorkerJob *lua_job = (LuaWorkerJob *)lua_newuserdata(L, sizeof(*lua_job));
  lua_job->job = job;
  luaL_getmetatable(L, API_TYPE_WORKER_JOB);
  lua_setmetatable(L, -2);
}

static const char **read_submit_string_array(lua_State *L, int table, const char *field, uint32_t max_count, uint32_t *count) {
  *count = 0;
  lua_getfield(L, table, field);
  if (lua_isnil(L, -1)) { lua_pop(L, 1); return NULL; }
  if (lua_isstring(L, -1)) {
    const char **items = (const char **)SDL_calloc(1, sizeof(*items));
    if (!items) luaL_error(L, "out of memory reading native Project run string");
    items[0] = lua_tostring(L, -1);
    lua_pop(L, 1);
    *count = 1;
    return items;
  }
  luaL_checktype(L, -1, LUA_TTABLE);
  size_t length = lua_rawlen(L, -1);
  luaL_argcheck(L, length <= max_count, table, "native Project run string table exceeds limit");
  const char **items = length ? (const char **)SDL_calloc(length, sizeof(*items)) : NULL;
  if (length && !items) luaL_error(L, "out of memory reading native Project run strings");
  for (size_t i = 0; i < length; i++) {
    lua_rawgeti(L, -1, (lua_Integer)i + 1);
    items[i] = luaL_checkstring(L, -1);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  *count = (uint32_t)length;
  return items;
}

static int pool_submit(lua_State *L) {
  LuaWorkerPool *pool = check_pool(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  AnvilWorkerJobSpec spec;
  memset(&spec, 0, sizeof(spec));
  spec.kind = opt_string_field(L, 2, "kind", NULL);
  const char *priority = opt_string_field(L, 2, "priority", "normal");
  if (strcmp(priority, "interactive") == 0) spec.priority = 1;
  else if (strcmp(priority, "background") == 0) spec.priority = -1;
  else luaL_argcheck(L, strcmp(priority, "normal") == 0, 2, "native worker priority must be interactive, normal, or background");
  spec.value = opt_string_field(L, 2, "value", NULL);
  spec.count = opt_int_field(L, 2, "count", 0);
  int sleep_ms = opt_int_field(L, 2, "sleep_ms", 0);
  if (sleep_ms < 0) sleep_ms = 0;
  spec.sleep_ms = (uint32_t)sleep_ms;
  spec.path = opt_string_field(L, 2, "path", NULL);
  spec.relpath = opt_string_field(L, 2, "relpath", NULL);
  spec.language = opt_string_field(L, 2, "language", NULL);
  spec.text = opt_lstring_field(L, 2, "text", &spec.text_len);
  spec.outline_query = opt_lstring_field(L, 2, "outline_query", &spec.outline_query_len);
  spec.usage_query = opt_lstring_field(L, 2, "usage_query", &spec.usage_query_len);
  spec.cancel_token = opt_string_field(L, 2, "cancel_token", NULL);
  spec.repository_root = opt_string_field(L, 2, "repository_root", NULL);
  spec.status_text = opt_lstring_field(L, 2, "status_text", &spec.status_text_len);
  spec.numstat_text = opt_lstring_field(L, 2, "numstat_text", &spec.numstat_text_len);
  spec.case_insensitive_paths = opt_bool_field(L, 2, "case_insensitive_paths", NULL);
  spec.parse_timeout_ms = opt_uint32_field(L, 2, "parse_timeout_ms", 0);
  spec.query_timeout_ms = opt_uint32_field(L, 2, "query_timeout_ms", 0);
  spec.match_limit = opt_uint32_field(L, 2, "match_limit", 0);
  spec.max_captures = opt_uint32_field(L, 2, "max_captures", 0);
  spec.usage_query_timeout_ms = opt_uint32_field(L, 2, "usage_query_timeout_ms", 0);
  spec.usage_match_limit = opt_uint32_field(L, 2, "usage_match_limit", 0);
  spec.usage_max_captures = opt_uint32_field(L, 2, "usage_max_captures", 0);
  spec.project_usage_cap = opt_uint32_field(L, 2, "project_usage_cap", 750000);
  spec.project_root = opt_string_field(L, 2, "project_root", NULL);
  spec.project_progress_files = opt_uint32_field(L, 2, "project_progress_files", 64);
  spec.project_publish_partial_snapshots = opt_bool_field(L, 2, "publish_partial_snapshots", NULL);
  spec.manifest_show_unsupported_files = opt_bool_field(L, 2, "show_unsupported_files", NULL);
  spec.project_scoped = opt_bool_field(L, 2, "project_scoped", NULL);
  spec.max_file_bytes = opt_uint32_field(L, 2, "max_file_bytes", 0);
  bool capture_present = false, line_present = false, compact_present = false;
  bool capture_paging = opt_bool_field(L, 2, "capture_paging", &capture_present);
  bool line_range_lookup = opt_bool_field(L, 2, "line_range_lookup", &line_present);
  bool compact_project_records = opt_bool_field(L, 2, "compact_project_records", &compact_present);
  if (!capture_present || capture_paging) spec.result_capabilities |= ANVIL_WORKER_TS_CAPTURE_PAGING;
  if (!line_present || line_range_lookup) spec.result_capabilities |= ANVIL_WORKER_TS_LINE_RANGE_LOOKUP;
  if (compact_project_records) spec.result_capabilities |= ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS;
  spec.result_capabilities_set = capture_present || line_present || compact_present;
  lua_getfield(L, 2, "previous_result");
  if (!lua_isnil(L, -1)) {
    LuaTreeSitterIndexResult *previous = check_treesitter_index_result(L, -1);
    spec.previous_result = previous->result;
  }
  lua_pop(L, 1);

  AnvilWorkerProjectBatchFileSpec *project_files = NULL;
  LuaProjectBuilder *transferred_builder = NULL;
  LuaProjectSnapshot *transferred_snapshot = NULL;
  LuaGitStatusSnapshot *transferred_git_status_snapshot = NULL;
  LuaMarkdownVaultSnapshot *transferred_markdown_vault_snapshot = NULL;
  LuaProjectSnapshot *query_snapshot = NULL;
  lua_getfield(L, 2, "project_builder");
  if (!lua_isnil(L, -1)) {
    transferred_builder = check_project_builder(L, -1);
    spec.project_builder = transferred_builder->builder;
    spec.project_builder_id = anvil_ts_project_builder_id(transferred_builder->builder);
    spec.transfer_project_builder = true;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "query_snapshot");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, spec.kind && strcmp(spec.kind, "project_snapshot_query_symbols") == 0, 2,
      "query_snapshot is only valid for Project symbol query jobs");
    query_snapshot = check_project_snapshot(L, -1);
    spec.project_query_snapshot = query_snapshot->snapshot;
  }
  lua_pop(L, 1);
  spec.project_query_offset = opt_uint32_field(L, 2, "offset", 0);
  spec.project_query_limit = opt_uint32_field(L, 2, "limit", 200);
  luaL_argcheck(L, spec.project_query_limit <= PROJECT_RECORD_PAGE_LIMIT, 2,
    "Project query limit exceeds 4096");
  lua_getfield(L, 2, "release_snapshot");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, spec.kind && strcmp(spec.kind, "project_snapshot_release") == 0, 2,
      "release_snapshot is only valid for project_snapshot_release jobs");
    transferred_snapshot = check_project_snapshot(L, -1);
    spec.project_snapshot_to_release = transferred_snapshot->snapshot;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "release_git_status_snapshot");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, spec.kind && strcmp(spec.kind, "filetree_git_status_snapshot_release") == 0, 2,
      "release_git_status_snapshot is only valid for File Tree Git status release jobs");
    transferred_git_status_snapshot = check_git_status_snapshot(L, -1);
    spec.git_status_snapshot_to_release = transferred_git_status_snapshot->snapshot;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "manifest");
  if (!lua_isnil(L, -1)) {
    spec.manifest_snapshot = check_project_file_manifest(L, -1)->snapshot;
  }
  lua_pop(L, 1);
  spec.markdown_vault_shallow_bytes = opt_uint32_field(L, 2, "shallow_note_bytes", 512 * 1024);
  lua_getfield(L, 2, "previous_vault_snapshot");
  if (!lua_isnil(L, -1)) {
    spec.previous_markdown_vault_snapshot = check_markdown_vault_snapshot(L, -1)->snapshot;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "release_markdown_vault_snapshot");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, spec.kind && strcmp(spec.kind, "markdown_vault_snapshot_release") == 0, 2,
      "release_markdown_vault_snapshot is only valid for Markdown vault release jobs");
    transferred_markdown_vault_snapshot = check_markdown_vault_snapshot(L, -1);
    spec.markdown_vault_snapshot_to_release = transferred_markdown_vault_snapshot->snapshot;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "project_builder_id");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, transferred_builder == NULL, 2,
      "native Project submission accepts project_builder or project_builder_id, not both");
    lua_Integer raw_id = luaL_checkinteger(L, -1);
    luaL_argcheck(L, raw_id > 0, 2, "invalid native Project builder id");
    spec.project_builder_id = (uint64_t)raw_id;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "base_snapshot");
  if (!lua_isnil(L, -1)) {
    luaL_argcheck(L, transferred_builder == NULL && spec.project_builder_id == 0, 2,
      "native Project submission accepts base_snapshot or an existing builder, not both");
    spec.project_base_snapshot = check_project_snapshot(L, -1)->snapshot;
  }
  lua_pop(L, 1);
  lua_getfield(L, 2, "files");
  if (lua_istable(L, -1)) {
    size_t file_count = lua_rawlen(L, -1);
    luaL_argcheck(L, file_count <= 4096 && file_count <= SIZE_MAX / sizeof(*project_files), 2,
      "native Project batch exceeds 4096-file limit");
    if (file_count) project_files = (AnvilWorkerProjectBatchFileSpec *)SDL_calloc(file_count, sizeof(*project_files));
    if (file_count && !project_files) { lua_pop(L, 1); return luaL_error(L, "out of memory preparing native Project batch"); }
    spec.project_files = project_files;
    spec.project_file_count = (uint32_t)file_count;
    for (uint32_t i = 0; i < spec.project_file_count; i++) {
      lua_rawgeti(L, -1, (int)i + 1);
      luaL_checktype(L, -1, LUA_TTABLE);
      AnvilWorkerProjectBatchFileSpec *file = &project_files[i];
      file->path = opt_string_field(L, -1, "path", NULL);
      file->relpath = opt_string_field(L, -1, "relpath", file->path);
      file->fingerprint = opt_string_field(L, -1, "fingerprint", "");
      file->language = opt_string_field(L, -1, "language", NULL);
      file->outline_query = opt_lstring_field(L, -1, "outline_query", &file->outline_query_len);
      file->usage_query = opt_lstring_field(L, -1, "usage_query", &file->usage_query_len);
      file->parse_timeout_ms = opt_uint32_field(L, -1, "parse_timeout_ms", 0);
      file->query_timeout_ms = opt_uint32_field(L, -1, "query_timeout_ms", 0);
      file->match_limit = opt_uint32_field(L, -1, "match_limit", 0);
      file->max_captures = opt_uint32_field(L, -1, "max_captures", 0);
      file->usage_query_timeout_ms = opt_uint32_field(L, -1, "usage_query_timeout_ms", 0);
      file->usage_match_limit = opt_uint32_field(L, -1, "usage_match_limit", 0);
      file->usage_max_captures = opt_uint32_field(L, -1, "usage_max_captures", 0);
      file->max_file_bytes = opt_uint32_field(L, -1, "max_file_bytes", 0);
      luaL_argcheck(L, file->path && file->language && file->outline_query, 2,
        "native Project batch file requires path, language, and outline_query");
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);

  spec.project_scan_paths = read_submit_string_array(L, 2, "scan_paths", 65536,
    &spec.project_scan_path_count);
  spec.project_remove_paths = read_submit_string_array(L, 2, "remove_paths", 65536,
    &spec.project_remove_path_count);
  spec.project_excluded_paths = read_submit_string_array(L, 2, "excluded_paths", 65536,
    &spec.project_excluded_path_count);
  spec.project_query_included_paths = read_submit_string_array(L, 2, "included_paths", 65536,
    &spec.project_query_included_path_count);
  spec.project_query_kinds = read_submit_string_array(L, 2, "kinds", 65536,
    &spec.project_query_kind_count);
  spec.project_query_parent_names = read_submit_string_array(L, 2, "parent_names", 65536,
    &spec.project_query_parent_name_count);
  spec.project_query_languages = read_submit_string_array(L, 2, "query_languages", 65536,
    &spec.project_query_language_count);
  spec.project_ignore_patterns = read_submit_string_array(L, 2, "ignore_patterns", 4096,
    &spec.project_ignore_pattern_count);
  AnvilWorkerProjectRunLanguageSpec *project_languages = NULL;
  const char ***language_patterns = NULL;
  lua_getfield(L, 2, "languages");
  if (lua_istable(L, -1)) {
    size_t language_count = lua_rawlen(L, -1);
    luaL_argcheck(L, language_count <= 256, 2, "native Project run exceeds 256 languages");
    project_languages = language_count
      ? (AnvilWorkerProjectRunLanguageSpec *)SDL_calloc(language_count, sizeof(*project_languages)) : NULL;
    language_patterns = language_count ? (const char ***)SDL_calloc(language_count, sizeof(*language_patterns)) : NULL;
    if (language_count && (!project_languages || !language_patterns)) return luaL_error(L, "out of memory reading native Project languages");
    spec.project_languages = project_languages;
    spec.project_language_count = (uint32_t)language_count;
    for (uint32_t i = 0; i < spec.project_language_count; i++) {
      lua_rawgeti(L, -1, (lua_Integer)i + 1);
      luaL_checktype(L, -1, LUA_TTABLE);
      AnvilWorkerProjectRunLanguageSpec *language = &project_languages[i];
      language->id = opt_string_field(L, -1, "id", NULL);
      language->grammar = opt_string_field(L, -1, "grammar", NULL);
      language_patterns[i] = read_submit_string_array(L, -1, "files", 4096, &language->file_pattern_count);
      language->file_patterns = language_patterns[i];
      language->outline_query = opt_lstring_field(L, -1, "outline_query", &language->outline_query_len);
      language->usage_query = opt_lstring_field(L, -1, "usage_query", &language->usage_query_len);
      language->parse_timeout_ms = opt_uint32_field(L, -1, "parse_timeout_ms", 1000);
      language->query_timeout_ms = opt_uint32_field(L, -1, "query_timeout_ms", 20);
      language->match_limit = opt_uint32_field(L, -1, "match_limit", 50000);
      language->max_captures = opt_uint32_field(L, -1, "max_captures", 50000);
      language->usage_query_timeout_ms = opt_uint32_field(L, -1, "usage_query_timeout_ms", 20);
      language->usage_match_limit = opt_uint32_field(L, -1, "usage_match_limit", 50000);
      language->usage_max_captures = opt_uint32_field(L, -1, "usage_max_captures", 50000);
      luaL_argcheck(L, language->id && language->grammar && language->outline_query && language->file_pattern_count, 2,
        "native Project run language requires id, grammar, files, and outline_query");
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  char *error = NULL;
  AnvilWorkerJob *job = anvil_worker_pool_submit(pool->pool, &spec, &error);
  SDL_free((void *)spec.project_scan_paths);
  SDL_free((void *)spec.project_remove_paths);
  SDL_free((void *)spec.project_excluded_paths);
  SDL_free((void *)spec.project_query_included_paths);
  SDL_free((void *)spec.project_query_kinds);
  SDL_free((void *)spec.project_query_parent_names);
  SDL_free((void *)spec.project_query_languages);
  SDL_free((void *)spec.project_ignore_patterns);
  for (uint32_t i = 0; i < spec.project_language_count; i++) SDL_free((void *)language_patterns[i]);
  SDL_free(language_patterns);
  SDL_free(project_languages);
  SDL_free(project_files);
  if (!job) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "submit failed");
    SDL_free(error);
    return 2;
  }
  if (transferred_builder && transferred_builder->builder) {
    /* The worker job retained the builder during submission. Drop the Lua
     * owner's reference and make the moved-from userdata harmless. */
    AnvilTSProjectBuilder *builder = transferred_builder->builder;
    transferred_builder->builder = NULL;
    anvil_ts_project_builder_release(builder);
  }
  if (transferred_snapshot && transferred_snapshot->snapshot) {
    AnvilTSProjectSnapshot *snapshot = transferred_snapshot->snapshot;
    transferred_snapshot->snapshot = NULL;
    anvil_ts_project_snapshot_release(snapshot);
  }
  if (transferred_git_status_snapshot && transferred_git_status_snapshot->snapshot) {
    AnvilGitStatusSnapshot *snapshot = transferred_git_status_snapshot->snapshot;
    transferred_git_status_snapshot->snapshot = NULL;
    anvil_git_status_snapshot_release(snapshot);
  }
  if (transferred_markdown_vault_snapshot && transferred_markdown_vault_snapshot->snapshot) {
    AnvilMarkdownVaultSnapshot *snapshot = transferred_markdown_vault_snapshot->snapshot;
    transferred_markdown_vault_snapshot->snapshot = NULL;
    anvil_markdown_vault_snapshot_release(snapshot);
  }
  push_job_handle(L, job);
  return 1;
}

static int pool_cancel(lua_State *L) {
  LuaWorkerPool *pool = check_pool(L, 1);
  LuaWorkerJob *job = check_job(L, 2);
  lua_pushboolean(L, anvil_worker_pool_cancel(pool->pool, job->job));
  return 1;
}

static void push_status(lua_State *L, AnvilWorkerJob *job) {
  lua_createtable(L, 0, 5);
  lua_pushinteger(L, (lua_Integer)anvil_worker_job_id(job));
  lua_setfield(L, -2, "id");
  lua_pushstring(L, anvil_worker_job_kind(job));
  lua_setfield(L, -2, "kind");
  lua_pushstring(L, anvil_worker_job_status_string(job));
  lua_setfield(L, -2, "status");
  lua_pushboolean(L, anvil_worker_job_cancel_requested(job));
  lua_setfield(L, -2, "cancel_requested");
}

static int pool_status(lua_State *L) {
  (void)check_pool(L, 1);
  LuaWorkerJob *job = check_job(L, 2);
  push_status(L, job->job);
  return 1;
}

static void push_treesitter_index_result_handle(lua_State *L, AnvilWorkerTreeSitterIndexResult *result) {
  LuaTreeSitterIndexResult *lua_result = (LuaTreeSitterIndexResult *)lua_newuserdata(L, sizeof(*lua_result));
  lua_result->result = result;
  luaL_getmetatable(L, API_TYPE_TREESITTER_INDEX_RESULT);
  lua_setmetatable(L, -2);
}

static void push_treesitter_capture(lua_State *L, AnvilWorkerTreeSitterIndexResult *result, const char *kind, uint32_t index) {
  const char *name = NULL;
  uint32_t name_len = 0, start_byte = 0, end_byte = 0, start_line = 0, start_col = 0, end_line = 0, end_col = 0;
  int32_t priority = 0;
  uint32_t match_id = 0, pattern_index = 0, capture_index = 0, order = 0;
  uint64_t node_id = 0;
  if (!anvil_worker_treesitter_index_result_capture_at(result, kind, index, &name, &name_len, &start_byte, &end_byte, &start_line, &start_col, &end_line, &end_col, &priority, &match_id, &pattern_index, &capture_index, &order, &node_id)) {
    lua_pushnil(L);
    return;
  }
  lua_createtable(L, 0, 12);
  lua_pushlstring(L, name ? name : "", name_len);
  lua_setfield(L, -2, "capture");
  lua_pushinteger(L, (lua_Integer)start_byte);
  lua_setfield(L, -2, "start_byte");
  lua_pushinteger(L, (lua_Integer)end_byte);
  lua_setfield(L, -2, "end_byte");
  lua_pushinteger(L, (lua_Integer)start_line);
  lua_setfield(L, -2, "start_line");
  lua_pushinteger(L, (lua_Integer)start_col);
  lua_setfield(L, -2, "start_col");
  lua_pushinteger(L, (lua_Integer)end_line);
  lua_setfield(L, -2, "end_line");
  lua_pushinteger(L, (lua_Integer)end_col);
  lua_setfield(L, -2, "end_col");
  lua_pushinteger(L, (lua_Integer)priority);
  lua_setfield(L, -2, "priority");
  lua_pushinteger(L, (lua_Integer)match_id);
  lua_setfield(L, -2, "match_id");
  lua_pushinteger(L, (lua_Integer)pattern_index);
  lua_setfield(L, -2, "pattern_index");
  lua_pushinteger(L, (lua_Integer)capture_index);
  lua_setfield(L, -2, "capture_index");
  lua_pushinteger(L, (lua_Integer)order);
  lua_setfield(L, -2, "order");
  lua_pushinteger(L, (lua_Integer)node_id);
  lua_setfield(L, -2, "node_id");
}

static void push_project_range(lua_State *L, const AnvilTSProjectRange *range) {
  lua_createtable(L, 0, 2);
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, (lua_Integer)range->start_point.row + 1); lua_setfield(L, -2, "line");
  lua_pushinteger(L, (lua_Integer)range->start_point.column + 1); lua_setfield(L, -2, "col");
  lua_setfield(L, -2, "start");
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, (lua_Integer)range->end_point.row + 1); lua_setfield(L, -2, "line");
  lua_pushinteger(L, (lua_Integer)range->end_point.column + 1); lua_setfield(L, -2, "col");
  lua_setfield(L, -2, "end");
}

static void set_project_location_fields(lua_State *L, const AnvilTSProjectRange *range) {
  lua_pushinteger(L, (lua_Integer)range->start_point.row + 1); lua_setfield(L, -2, "start_line");
  lua_pushinteger(L, (lua_Integer)range->start_point.column + 1); lua_setfield(L, -2, "start_col");
  lua_pushinteger(L, (lua_Integer)range->end_point.row + 1); lua_setfield(L, -2, "end_line");
  lua_pushinteger(L, (lua_Integer)range->end_point.column + 1); lua_setfield(L, -2, "end_col");
  lua_pushinteger(L, (lua_Integer)range->start_byte); lua_setfield(L, -2, "start_byte");
  lua_pushinteger(L, (lua_Integer)range->end_byte); lua_setfield(L, -2, "end_byte");
  push_project_range(L, range); lua_setfield(L, -2, "range");
}

static void set_project_path_fields(lua_State *L, AnvilWorkerTreeSitterIndexResult *result) {
  const char *path = anvil_worker_treesitter_index_result_project_path(result);
  const char *relpath = anvil_worker_treesitter_index_result_project_relpath(result);
  const char *language = anvil_worker_treesitter_index_result_language(result);
  lua_pushstring(L, path ? path : ""); lua_setfield(L, -2, "path");
  lua_pushstring(L, relpath ? relpath : (path ? path : "")); lua_setfield(L, -2, "file");
  lua_pushstring(L, relpath ? relpath : (path ? path : "")); lua_setfield(L, -2, "relpath");
  lua_pushstring(L, language ? language : ""); lua_setfield(L, -2, "language_id");
}

static void push_project_symbol(lua_State *L, AnvilWorkerTreeSitterIndexResult *result, uint32_t index) {
  AnvilTSProjectSymbolView symbol;
  if (!anvil_worker_treesitter_index_result_project_symbol_at(result, index, &symbol)) { lua_pushnil(L); return; }
  lua_createtable(L, 0, 22);
  lua_pushlstring(L, symbol.name, symbol.name_len); lua_setfield(L, -2, "name");
  lua_pushlstring(L, symbol.name, symbol.name_len); lua_setfield(L, -2, "text");
  lua_pushlstring(L, symbol.kind, symbol.kind_len); lua_setfield(L, -2, "kind");
  if (symbol.signature) { lua_pushlstring(L, symbol.signature, symbol.signature_len); lua_setfield(L, -2, "signature"); }
  if (symbol.declaration) { lua_pushlstring(L, symbol.declaration, symbol.declaration_len); lua_setfield(L, -2, "declaration"); }
  if (symbol.has_declaration_name_span) {
    lua_createtable(L, 2, 0);
    lua_pushinteger(L, symbol.declaration_name_start); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, symbol.declaration_name_end); lua_rawseti(L, -2, 2);
    lua_setfield(L, -2, "declaration_name_span");
  }
  set_project_location_fields(L, &symbol.range);
  push_project_range(L, &symbol.name_range); lua_setfield(L, -2, "name_range");
  lua_pushinteger(L, symbol.index); lua_setfield(L, -2, "index");
  lua_pushinteger(L, symbol.depth); lua_setfield(L, -2, "depth");
  if (symbol.parent != UINT32_MAX) {
    lua_pushinteger(L, symbol.parent); lua_setfield(L, -2, "parent");
    AnvilTSProjectSymbolView parent;
    if (anvil_worker_treesitter_index_result_project_symbol_at(result, symbol.parent - 1, &parent)) {
      lua_pushlstring(L, parent.name, parent.name_len); lua_setfield(L, -2, "parent_name");
    }
  }
  lua_createtable(L, (int)symbol.child_count, 0);
  for (uint32_t i = 0; i < symbol.child_count; i++) {
    lua_pushinteger(L, symbol.children[i]); lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "children");
  set_project_path_fields(L, result);
}

static void push_project_usage(lua_State *L, AnvilWorkerTreeSitterIndexResult *result, uint32_t index) {
  AnvilTSProjectUsageView usage;
  if (!anvil_worker_treesitter_index_result_project_usage_at(result, index, &usage)) { lua_pushnil(L); return; }
  lua_createtable(L, 0, 20);
  lua_pushlstring(L, usage.name, usage.name_len); lua_setfield(L, -2, "name");
  lua_pushlstring(L, usage.name, usage.name_len); lua_setfield(L, -2, "text");
  lua_pushlstring(L, usage.capture, usage.capture_len); lua_setfield(L, -2, "capture");
  lua_pushlstring(L, usage.kind, usage.kind_len); lua_setfield(L, -2, "kind");
  lua_pushlstring(L, usage.line_text, usage.line_text_len); lua_setfield(L, -2, "line_text");
  lua_pushboolean(L, usage.is_declaration); lua_setfield(L, -2, "is_declaration");
  lua_pushboolean(L, true); lua_setfield(L, -2, "workspace_tree_sitter_fallback");
  set_project_location_fields(L, &usage.range);
  set_project_path_fields(L, result);
}

static void set_project_file_path_fields(lua_State *L, AnvilTSProjectFileResult *file) {
  const char *path = anvil_ts_project_file_path(file);
  const char *relpath = anvil_ts_project_file_relpath(file);
  const char *language = anvil_ts_project_file_language(file);
  lua_pushstring(L, path ? path : ""); lua_setfield(L, -2, "path");
  lua_pushstring(L, relpath ? relpath : (path ? path : "")); lua_setfield(L, -2, "file");
  lua_pushstring(L, relpath ? relpath : (path ? path : "")); lua_setfield(L, -2, "relpath");
  lua_pushstring(L, language ? language : ""); lua_setfield(L, -2, "language_id");
}

static void push_snapshot_symbol(lua_State *L, AnvilTSProjectFileResult *file, uint32_t index) {
  AnvilTSProjectSymbolView symbol;
  if (!anvil_ts_project_file_symbol_at(file, index, &symbol)) { lua_pushnil(L); return; }
  lua_createtable(L, 0, 22);
  lua_pushlstring(L, symbol.name, symbol.name_len); lua_setfield(L, -2, "name");
  lua_pushlstring(L, symbol.name, symbol.name_len); lua_setfield(L, -2, "text");
  lua_pushlstring(L, symbol.kind, symbol.kind_len); lua_setfield(L, -2, "kind");
  if (symbol.signature) { lua_pushlstring(L, symbol.signature, symbol.signature_len); lua_setfield(L, -2, "signature"); }
  if (symbol.declaration) { lua_pushlstring(L, symbol.declaration, symbol.declaration_len); lua_setfield(L, -2, "declaration"); }
  if (symbol.has_declaration_name_span) {
    lua_createtable(L, 2, 0);
    lua_pushinteger(L, symbol.declaration_name_start); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, symbol.declaration_name_end); lua_rawseti(L, -2, 2);
    lua_setfield(L, -2, "declaration_name_span");
  }
  set_project_location_fields(L, &symbol.range);
  push_project_range(L, &symbol.name_range); lua_setfield(L, -2, "name_range");
  lua_pushinteger(L, symbol.index); lua_setfield(L, -2, "index");
  lua_pushinteger(L, symbol.depth); lua_setfield(L, -2, "depth");
  if (symbol.parent != UINT32_MAX) {
    lua_pushinteger(L, symbol.parent); lua_setfield(L, -2, "parent");
    AnvilTSProjectSymbolView parent;
    if (anvil_ts_project_file_symbol_at(file, symbol.parent - 1, &parent)) {
      lua_pushlstring(L, parent.name, parent.name_len); lua_setfield(L, -2, "parent_name");
    }
  }
  lua_createtable(L, (int)symbol.child_count, 0);
  for (uint32_t i = 0; i < symbol.child_count; i++) {
    lua_pushinteger(L, symbol.children[i]); lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "children");
  set_project_file_path_fields(L, file);
}

static void push_snapshot_usage(lua_State *L, AnvilTSProjectFileResult *file, uint32_t index) {
  AnvilTSProjectUsageView usage;
  if (!anvil_ts_project_file_usage_at(file, index, &usage)) { lua_pushnil(L); return; }
  lua_createtable(L, 0, 20);
  lua_pushlstring(L, usage.name, usage.name_len); lua_setfield(L, -2, "name");
  lua_pushlstring(L, usage.name, usage.name_len); lua_setfield(L, -2, "text");
  lua_pushlstring(L, usage.capture, usage.capture_len); lua_setfield(L, -2, "capture");
  lua_pushlstring(L, usage.kind, usage.kind_len); lua_setfield(L, -2, "kind");
  lua_pushlstring(L, usage.line_text, usage.line_text_len); lua_setfield(L, -2, "line_text");
  lua_pushboolean(L, usage.is_declaration); lua_setfield(L, -2, "is_declaration");
  lua_pushboolean(L, true); lua_setfield(L, -2, "workspace_tree_sitter_fallback");
  set_project_location_fields(L, &usage.range);
  set_project_file_path_fields(L, file);
}

static int treesitter_index_result_summary(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  lua_createtable(L, 0, 6);
  lua_pushstring(L, anvil_worker_treesitter_index_result_language(result->result));
  lua_setfield(L, -2, "language");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_byte_len(result->result));
  lua_setfield(L, -2, "byte_len");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_line_count(result->result));
  lua_setfield(L, -2, "line_count");
  lua_createtable(L, 0, 22);
  lua_pushnumber(L, anvil_worker_treesitter_index_result_precise_parse_ms(result->result));
  lua_setfield(L, -2, "parse_ms");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_block_parse_ms(result->result));
  lua_setfield(L, -2, "block_parse_ms");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_inline_parse_ms(result->result));
  lua_setfield(L, -2, "inline_parse_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_precise_total_ms(result->result));
  lua_setfield(L, -2, "total_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_prepare_input_ms(result->result));
  lua_setfield(L, -2, "prepare_input_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_parser_setup_ms(result->result));
  lua_setfield(L, -2, "parser_setup_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_project_record_ms(result->result));
  lua_setfield(L, -2, "project_record_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_precise_query_ms(result->result, "outline"));
  lua_setfield(L, -2, "outline_query_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_query_compile_ms(result->result, "outline"));
  lua_setfield(L, -2, "outline_query_compile_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_line_index_ms(result->result, "outline"));
  lua_setfield(L, -2, "outline_line_index_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_precise_query_ms(result->result, "usage"));
  lua_setfield(L, -2, "usage_query_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_query_compile_ms(result->result, "usage"));
  lua_setfield(L, -2, "usage_query_compile_ms");
  lua_pushnumber(L, anvil_worker_treesitter_index_result_line_index_ms(result->result, "usage"));
  lua_setfield(L, -2, "usage_line_index_ms");
  lua_pushboolean(L, anvil_worker_treesitter_index_result_incremental(result->result));
  lua_setfield(L, -2, "incremental");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_reused_block_capture_count(result->result));
  lua_setfield(L, -2, "reused_block_captures");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_reused_inline_count(result->result));
  lua_setfield(L, -2, "reused_inline_regions");
  lua_pushboolean(L, anvil_worker_treesitter_index_result_parser_reused(result->result));
  lua_setfield(L, -2, "parser_reused");
  int query_cache_hits = 0;
  int query_cache_misses = 0;
  const char *metric_kinds[] = { "outline", "usage" };
  for (int i = 0; i < 2; i++) {
    if (anvil_worker_treesitter_index_result_query_cache_hit(result->result, metric_kinds[i])) query_cache_hits++;
    if (anvil_worker_treesitter_index_result_query_cache_miss(result->result, metric_kinds[i])) query_cache_misses++;
  }
  lua_pushinteger(L, query_cache_hits);
  lua_setfield(L, -2, "query_cache_hits");
  lua_pushinteger(L, query_cache_misses);
  lua_setfield(L, -2, "query_cache_misses");
  uint32_t capabilities = anvil_worker_treesitter_index_result_capabilities(result->result);
  int skipped_line_indexes = 0;
  if ((capabilities & ANVIL_WORKER_TS_LINE_RANGE_LOOKUP) == 0) {
    if (anvil_worker_treesitter_index_result_capture_count(result->result, "outline") > 0) skipped_line_indexes++;
    if (anvil_worker_treesitter_index_result_capture_count(result->result, "usage") > 0) skipped_line_indexes++;
  }
  lua_pushinteger(L, skipped_line_indexes);
  lua_setfield(L, -2, "line_indexes_skipped");
  lua_setfield(L, -2, "metrics");
  lua_createtable(L, 0, 3);
  lua_pushboolean(L, (capabilities & ANVIL_WORKER_TS_CAPTURE_PAGING) != 0);
  lua_setfield(L, -2, "capture_paging");
  lua_pushboolean(L, (capabilities & ANVIL_WORKER_TS_LINE_RANGE_LOOKUP) != 0);
  lua_setfield(L, -2, "line_range_lookup");
  lua_pushboolean(L, (capabilities & ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS) != 0);
  lua_setfield(L, -2, "compact_project_records");
  lua_setfield(L, -2, "capabilities");
  if ((capabilities & ANVIL_WORKER_TS_COMPACT_PROJECT_RECORDS) != 0) {
    lua_createtable(L, 0, 4);
    const char *path = anvil_worker_treesitter_index_result_project_path(result->result);
    const char *relpath = anvil_worker_treesitter_index_result_project_relpath(result->result);
    lua_pushstring(L, path ? path : ""); lua_setfield(L, -2, "path");
    lua_pushstring(L, relpath ? relpath : ""); lua_setfield(L, -2, "relpath");
    lua_pushinteger(L, anvil_worker_treesitter_index_result_project_symbol_count(result->result)); lua_setfield(L, -2, "symbol_count");
    lua_pushinteger(L, anvil_worker_treesitter_index_result_project_usage_count(result->result)); lua_setfield(L, -2, "usage_count");
    lua_setfield(L, -2, "project");
  }
  const char *kinds[] = { "outline", "usage" };
  for (int i = 0; i < 2; ++i) {
    const char *kind = kinds[i];
    lua_createtable(L, 0, 4);
    lua_pushstring(L, anvil_worker_treesitter_index_result_status(result->result, kind));
    lua_setfield(L, -2, "status");
    lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_capture_count(result->result, kind));
    lua_setfield(L, -2, "capture_count");
    lua_pushboolean(L, anvil_worker_treesitter_index_result_exceeded_match_limit(result->result, kind));
    lua_setfield(L, -2, "exceeded_match_limit");
    lua_pushboolean(L, anvil_worker_treesitter_index_result_line_indexed(result->result, kind));
    lua_setfield(L, -2, "line_indexed");
    lua_pushboolean(L, anvil_worker_treesitter_index_result_query_cache_hit(result->result, kind));
    lua_setfield(L, -2, "query_cache_hit");
    lua_pushboolean(L, anvil_worker_treesitter_index_result_query_cache_miss(result->result, kind));
    lua_setfield(L, -2, "query_cache_miss");
    const char *error = anvil_worker_treesitter_index_result_error(result->result, kind);
    if (error) {
      lua_pushstring(L, error);
      lua_setfield(L, -2, "error");
    }
    lua_setfield(L, -2, kind);
  }
  return 1;
}

static void push_project_snapshot(lua_State *L, AnvilTSProjectSnapshot *snapshot) {
  LuaProjectSnapshot *lua_snapshot = (LuaProjectSnapshot *)lua_newuserdata(L, sizeof(*lua_snapshot));
  lua_snapshot->snapshot = snapshot;
  luaL_getmetatable(L, API_TYPE_PROJECT_SNAPSHOT);
  lua_setmetatable(L, -2);
}

static void push_git_status_snapshot(lua_State *L, AnvilGitStatusSnapshot *snapshot) {
  LuaGitStatusSnapshot *lua_snapshot = (LuaGitStatusSnapshot *)lua_newuserdata(L, sizeof(*lua_snapshot));
  lua_snapshot->snapshot = snapshot;
  luaL_getmetatable(L, API_TYPE_GIT_STATUS_SNAPSHOT);
  lua_setmetatable(L, -2);
}

static int git_status_snapshot_close(lua_State *L) {
  LuaGitStatusSnapshot *snapshot = (LuaGitStatusSnapshot *)luaL_checkudata(L, 1, API_TYPE_GIT_STATUS_SNAPSHOT);
  bool released = snapshot && snapshot->snapshot;
  if (released) {
    anvil_git_status_snapshot_release(snapshot->snapshot);
    snapshot->snapshot = NULL;
  }
  lua_pushboolean(L, released);
  return 1;
}

static int git_status_snapshot_summary(lua_State *L) {
  LuaGitStatusSnapshot *snapshot = check_git_status_snapshot(L, 1);
  AnvilGitStatusSummary summary;
  anvil_git_status_snapshot_summary(snapshot->snapshot, &summary);
  lua_createtable(L, 0, 9);
#define SET_SUMMARY_INTEGER(name) do { lua_pushnumber(L, (lua_Number)summary.name); lua_setfield(L, -2, #name); } while (0)
  SET_SUMMARY_INTEGER(status_bytes);
  SET_SUMMARY_INTEGER(numstat_bytes);
  SET_SUMMARY_INTEGER(status_records);
  SET_SUMMARY_INTEGER(numstat_records);
  SET_SUMMARY_INTEGER(parent_edges);
  SET_SUMMARY_INTEGER(subtree_summaries);
  SET_SUMMARY_INTEGER(rejected_records);
  SET_SUMMARY_INTEGER(entry_count);
#undef SET_SUMMARY_INTEGER
  lua_pushnumber(L, summary.build_ms); lua_setfield(L, -2, "build_ms");
  return 1;
}

static int git_status_snapshot_lookup(lua_State *L) {
  LuaGitStatusSnapshot *snapshot = check_git_status_snapshot(L, 1);
  size_t path_len = 0;
  const char *path = luaL_checklstring(L, 2, &path_len);
  bool is_directory = lua_toboolean(L, 3) != 0;
  AnvilGitStatusLookup lookup;
  if (!anvil_git_status_snapshot_lookup(snapshot->snapshot, path, path_len, is_directory, &lookup)) {
    lua_pushnil(L);
    return 1;
  }
  lua_createtable(L, 0, 3);
  const char *kind = anvil_git_status_kind_name(lookup.kind);
  if (kind) { lua_pushstring(L, kind); lua_setfield(L, -2, "kind"); }
  if (lookup.has_numstat) {
    lua_pushnumber(L, (lua_Number)lookup.additions); lua_setfield(L, -2, "additions");
    lua_pushnumber(L, (lua_Number)lookup.deletions); lua_setfield(L, -2, "deletions");
  }
  return 1;
}

static void push_manifest_handle(lua_State *L, AnvilProjectFileManifestSnapshot *snapshot) {
  LuaProjectFileManifest *manifest = (LuaProjectFileManifest *)lua_newuserdata(L, sizeof(*manifest));
  manifest->snapshot = snapshot;
  luaL_getmetatable(L, API_TYPE_PROJECT_FILE_MANIFEST);
  lua_setmetatable(L, -2);
}

static int project_file_manifest_close(lua_State *L) {
  LuaProjectFileManifest *manifest = (LuaProjectFileManifest *)luaL_checkudata(L, 1, API_TYPE_PROJECT_FILE_MANIFEST);
  bool released = manifest && manifest->snapshot;
  if (released) { anvil_project_file_manifest_release(manifest->snapshot); manifest->snapshot = NULL; }
  lua_pushboolean(L, released);
  return 1;
}

static int project_file_manifest_summary(lua_State *L) {
  LuaProjectFileManifest *manifest = check_project_file_manifest(L, 1);
  AnvilProjectFileManifestSummary summary;
  anvil_project_file_manifest_summary(manifest->snapshot, &summary);
  lua_createtable(L, 0, 9);
#define SET_MANIFEST_SUMMARY(name) do { lua_pushnumber(L, (lua_Number)summary.name); lua_setfield(L, -2, #name); } while (0)
  SET_MANIFEST_SUMMARY(records); SET_MANIFEST_SUMMARY(files); SET_MANIFEST_SUMMARY(directories);
  SET_MANIFEST_SUMMARY(markdown_files); SET_MANIFEST_SUMMARY(attachments); SET_MANIFEST_SUMMARY(other_files);
  SET_MANIFEST_SUMMARY(inaccessible_entries); SET_MANIFEST_SUMMARY(total_bytes);
#undef SET_MANIFEST_SUMMARY
  lua_pushnumber(L, summary.scan_ms); lua_setfield(L, -2, "scan_ms");
  return 1;
}

static void push_manifest_record(lua_State *L, const AnvilProjectFileManifestRecord *record) {
  lua_createtable(L, 0, 5);
  lua_pushstring(L, record->absolute_path); lua_setfield(L, -2, "absolute_path");
  lua_pushstring(L, record->relative_path); lua_setfield(L, -2, "relative_path");
  lua_pushstring(L, anvil_manifest_entry_kind_name(record->kind)); lua_setfield(L, -2, "kind");
  lua_pushnumber(L, (lua_Number)record->size); lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number)record->modified); lua_setfield(L, -2, "modified");
}

static int project_file_manifest_page(lua_State *L) {
  LuaProjectFileManifest *manifest = check_project_file_manifest(L, 1);
  uint64_t offset = (uint64_t)luaL_optinteger(L, 2, 0);
  uint32_t limit = (uint32_t)luaL_optinteger(L, 3, 256);
  luaL_argcheck(L, limit <= PROJECT_RECORD_PAGE_LIMIT, 3, "manifest page limit exceeds 4096");
  uint64_t count = anvil_project_file_manifest_count(manifest->snapshot);
  uint64_t available = offset < count ? count - offset : 0;
  uint32_t returned = available < limit ? (uint32_t)available : limit;
  lua_createtable(L, (int)returned, 3);
  for (uint32_t i = 0; i < returned; i++) {
    AnvilProjectFileManifestRecord record;
    if (anvil_project_file_manifest_record_at(manifest->snapshot, offset + i, &record)) push_manifest_record(L, &record);
    else lua_pushnil(L);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushnumber(L, (lua_Number)count); lua_setfield(L, -2, "total");
  lua_pushnumber(L, (lua_Number)(offset + returned)); lua_setfield(L, -2, "next_offset");
  lua_pushboolean(L, offset + returned < count); lua_setfield(L, -2, "has_more");
  return 1;
}

static int project_file_manifest_lookup(lua_State *L) {
  LuaProjectFileManifest *manifest = check_project_file_manifest(L, 1);
  const char *path = luaL_checkstring(L, 2);
  AnvilProjectFileManifestRecord record;
  if (!anvil_project_file_manifest_lookup(manifest->snapshot, path, &record)) { lua_pushnil(L); return 1; }
  push_manifest_record(L, &record);
  return 1;
}

static void push_string_list(lua_State *L, const char *const *items, uint32_t count) {
  lua_createtable(L, (int)count, 0);
  for (uint32_t i = 0; i < count; i++) { lua_pushstring(L, items[i]); lua_rawseti(L, -2, (int)i + 1); }
}

static void push_markdown_vault_note(lua_State *L, const AnvilMarkdownVaultNoteView *note) {
  lua_createtable(L, 0, 18);
  lua_pushstring(L, "note"); lua_setfield(L, -2, "kind");
  lua_pushstring(L, note->absolute_path); lua_setfield(L, -2, "abs_path");
  lua_pushstring(L, note->relative_path); lua_setfield(L, -2, "rel_path");
  lua_pushstring(L, note->display_name); lua_setfield(L, -2, "display_name");
  lua_pushnumber(L, (lua_Number)note->size); lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number)note->modified); lua_setfield(L, -2, "modified");
  lua_pushboolean(L, note->shallow); lua_setfield(L, -2, "shallow");
  lua_pushinteger(L, note->fact_signature); lua_setfield(L, -2, "fact_signature");
  push_string_list(L, note->aliases, note->alias_count); lua_setfield(L, -2, "aliases");
  push_string_list(L, note->tags, note->tag_count); lua_setfield(L, -2, "tags");
  push_string_list(L, note->preview, note->preview_count); lua_setfield(L, -2, "embed_preview");
  lua_createtable(L, (int)note->metadata_count, 0);
  for (uint32_t i = 0; i < note->metadata_count; i++) {
    const AnvilMarkdownVaultMetadataView *meta = &note->metadata[i];
    if (!meta->list && meta->value_count == 1) lua_pushstring(L, meta->values[0]);
    else push_string_list(L, meta->values, meta->value_count);
    lua_setfield(L, -2, meta->key);
  }
  lua_setfield(L, -2, "frontmatter");

  lua_createtable(L, (int)note->heading_count, 0);
  int headings_table = lua_gettop(L);
  lua_createtable(L, 0, (int)note->heading_count); int slug_table = lua_gettop(L);
  lua_createtable(L, 0, (int)note->heading_count); int text_table = lua_gettop(L);
  lua_createtable(L, 0, (int)note->heading_count); int path_table = lua_gettop(L);
  for (uint32_t i = 0; i < note->heading_count; i++) {
    const AnvilMarkdownVaultHeadingView *heading = &note->headings[i];
    lua_createtable(L, 0, 8);
    lua_pushstring(L, "heading"); lua_setfield(L, -2, "type");
    lua_pushstring(L, heading->text); lua_setfield(L, -2, "text");
    lua_pushstring(L, heading->slug); lua_setfield(L, -2, "slug");
    lua_pushstring(L, heading->path_text); lua_setfield(L, -2, "path_text");
    lua_pushstring(L, heading->path_slug); lua_setfield(L, -2, "path_slug");
    lua_pushinteger(L, heading->line); lua_setfield(L, -2, "line");
    lua_pushinteger(L, heading->level); lua_setfield(L, -2, "level");
    push_string_list(L, heading->preview, heading->preview_count); lua_setfield(L, -2, "embed_preview");
    lua_pushvalue(L, -1); lua_rawseti(L, headings_table, (int)i + 1);
    lua_pushvalue(L, -1); lua_setfield(L, slug_table, heading->slug);
    lua_pushvalue(L, -1); lua_setfield(L, text_table, heading->slug);
    lua_setfield(L, path_table, heading->path_slug);
  }
  lua_setfield(L, -5, "headings_by_path");
  lua_setfield(L, -4, "headings_by_text");
  lua_setfield(L, -3, "headings_by_slug");
  lua_setfield(L, -2, "headings");

  lua_createtable(L, (int)note->block_count, 0); int blocks_table = lua_gettop(L);
  lua_createtable(L, 0, (int)note->block_count); int blocks_by_id = lua_gettop(L);
  for (uint32_t i = 0; i < note->block_count; i++) {
    const AnvilMarkdownVaultBlockView *block = &note->blocks[i];
    lua_createtable(L, 0, 6);
    lua_pushstring(L, "block"); lua_setfield(L, -2, "type");
    lua_pushstring(L, block->id); lua_setfield(L, -2, "id");
    lua_pushinteger(L, block->line); lua_setfield(L, -2, "line");
    lua_pushinteger(L, block->col1); lua_setfield(L, -2, "col1");
    lua_pushinteger(L, block->col2); lua_setfield(L, -2, "col2");
    push_string_list(L, block->preview, block->preview_count); lua_setfield(L, -2, "embed_preview");
    lua_pushvalue(L, -1); lua_rawseti(L, blocks_table, (int)i + 1);
    lua_setfield(L, blocks_by_id, block->id);
  }
  lua_setfield(L, -3, "blocks_by_id"); lua_setfield(L, -2, "blocks");

  lua_createtable(L, (int)note->link_count, 0);
  for (uint32_t i = 0; i < note->link_count; i++) {
    const AnvilMarkdownVaultLinkView *link = &note->links[i];
    lua_createtable(L, 0, 8);
    lua_pushstring(L, link->kind); lua_setfield(L, -2, "kind");
    lua_pushstring(L, link->raw_target); lua_setfield(L, -2, "raw_target");
    lua_pushstring(L, link->path); lua_setfield(L, -2, "path");
    if (link->alias) { lua_pushstring(L, link->alias); lua_setfield(L, -2, "alias"); }
    lua_pushinteger(L, link->source_line); lua_setfield(L, -2, "source_line");
    lua_pushinteger(L, link->source_col1); lua_setfield(L, -2, "source_col1");
    lua_pushinteger(L, link->source_col2); lua_setfield(L, -2, "source_col2");
    if (link->subtarget) {
      lua_createtable(L, 0, 2);
      lua_pushstring(L, link->block_subtarget ? "block" : "heading"); lua_setfield(L, -2, "type");
      lua_pushstring(L, link->subtarget); lua_setfield(L, -2, link->block_subtarget ? "id" : "text");
      lua_setfield(L, -2, "subtarget");
    }
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "outbound_links");
}

static void push_markdown_vault_attachment(lua_State *L, const AnvilMarkdownVaultAttachmentView *entry) {
  lua_createtable(L, 0, 6);
  lua_pushstring(L, "attachment"); lua_setfield(L, -2, "kind");
  lua_pushstring(L, entry->absolute_path); lua_setfield(L, -2, "abs_path");
  lua_pushstring(L, entry->relative_path); lua_setfield(L, -2, "rel_path");
  lua_pushstring(L, entry->display_name); lua_setfield(L, -2, "display_name");
  lua_pushnumber(L, (lua_Number)entry->size); lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number)entry->modified); lua_setfield(L, -2, "modified");
}

static void push_markdown_vault_handle(lua_State *L, AnvilMarkdownVaultSnapshot *snapshot) {
  LuaMarkdownVaultSnapshot *lua_snapshot = (LuaMarkdownVaultSnapshot *)lua_newuserdata(L, sizeof(*lua_snapshot));
  lua_snapshot->snapshot = snapshot; luaL_getmetatable(L, API_TYPE_MARKDOWN_VAULT_SNAPSHOT); lua_setmetatable(L, -2);
}

static int markdown_vault_close(lua_State *L) {
  LuaMarkdownVaultSnapshot *snapshot = (LuaMarkdownVaultSnapshot *)luaL_checkudata(L, 1, API_TYPE_MARKDOWN_VAULT_SNAPSHOT);
  bool released = snapshot && snapshot->snapshot;
  if (released) { anvil_markdown_vault_snapshot_release(snapshot->snapshot); snapshot->snapshot = NULL; }
  lua_pushboolean(L, released); return 1;
}

static int markdown_vault_summary(lua_State *L) {
  LuaMarkdownVaultSnapshot *snapshot = check_markdown_vault_snapshot(L, 1); AnvilMarkdownVaultSummary summary;
  anvil_markdown_vault_snapshot_summary(snapshot->snapshot, &summary); lua_createtable(L, 0, 11);
#define SET_VAULT_SUMMARY(name) do { lua_pushnumber(L, (lua_Number)summary.name); lua_setfield(L, -2, #name); } while (0)
  SET_VAULT_SUMMARY(note_count); SET_VAULT_SUMMARY(attachment_count); SET_VAULT_SUMMARY(headings);
  SET_VAULT_SUMMARY(blocks); SET_VAULT_SUMMARY(links); SET_VAULT_SUMMARY(bytes_read);
  SET_VAULT_SUMMARY(shallow_notes); SET_VAULT_SUMMARY(failed_notes);
  SET_VAULT_SUMMARY(reused_notes); SET_VAULT_SUMMARY(rebuilt_notes);
#undef SET_VAULT_SUMMARY
  lua_pushnumber(L, summary.build_ms); lua_setfield(L, -2, "build_ms"); return 1;
}

static int markdown_vault_note(lua_State *L) {
  LuaMarkdownVaultSnapshot *snapshot = check_markdown_vault_snapshot(L, 1); const char *path = luaL_checkstring(L, 2); uint32_t index;
  AnvilMarkdownVaultNoteView note;
  if (!anvil_markdown_vault_note_lookup(snapshot->snapshot, path, &index) || !anvil_markdown_vault_note_at(snapshot->snapshot, index, &note)) { lua_pushnil(L); return 1; }
  push_markdown_vault_note(L, &note); return 1;
}

static int markdown_vault_attachment(lua_State *L) {
  LuaMarkdownVaultSnapshot *snapshot = check_markdown_vault_snapshot(L, 1); const char *path = luaL_checkstring(L, 2); uint32_t index;
  AnvilMarkdownVaultAttachmentView entry;
  if (!anvil_markdown_vault_attachment_lookup(snapshot->snapshot, path, &index) || !anvil_markdown_vault_attachment_at(snapshot->snapshot, index, &entry)) { lua_pushnil(L); return 1; }
  push_markdown_vault_attachment(L, &entry); return 1;
}

static int markdown_vault_resolve(lua_State *L, bool attachments) {
  LuaMarkdownVaultSnapshot *snapshot = check_markdown_vault_snapshot(L, 1); const char *target = luaL_checkstring(L, 2);
  uint32_t total = attachments ? anvil_markdown_vault_resolve_attachments(snapshot->snapshot, target, NULL, 0)
    : anvil_markdown_vault_resolve_notes(snapshot->snapshot, target, NULL, 0);
  uint32_t count = total > 64 ? 64 : total; uint32_t *indices = count ? (uint32_t *)SDL_malloc((size_t)count * sizeof(*indices)) : NULL;
  if (count) {
    if (attachments) anvil_markdown_vault_resolve_attachments(snapshot->snapshot, target, indices, count);
    else anvil_markdown_vault_resolve_notes(snapshot->snapshot, target, indices, count);
  }
  lua_createtable(L, (int)count, 2);
  for (uint32_t i = 0; i < count; i++) {
    if (attachments) { AnvilMarkdownVaultAttachmentView entry; anvil_markdown_vault_attachment_at(snapshot->snapshot, indices[i], &entry); push_markdown_vault_attachment(L, &entry); }
    else { AnvilMarkdownVaultNoteView note; anvil_markdown_vault_note_at(snapshot->snapshot, indices[i], &note); push_markdown_vault_note(L, &note); }
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, total); lua_setfield(L, -2, "total"); lua_pushboolean(L, total > count); lua_setfield(L, -2, "truncated");
  SDL_free(indices); return 1;
}
static int markdown_vault_resolve_notes_lua(lua_State *L) { return markdown_vault_resolve(L, false); }
static int markdown_vault_resolve_attachments_lua(lua_State *L) { return markdown_vault_resolve(L, true); }

static int markdown_vault_linked_notes_lua(lua_State *L) {
  LuaMarkdownVaultSnapshot *snapshot = check_markdown_vault_snapshot(L, 1); const char *target = luaL_checkstring(L, 2);
  uint32_t total = anvil_markdown_vault_linked_notes(snapshot->snapshot, target, NULL, 0);
  uint32_t count = total > 4096 ? 4096 : total; uint32_t *indices = count ? (uint32_t *)SDL_malloc((size_t)count * sizeof(*indices)) : NULL;
  if (count) anvil_markdown_vault_linked_notes(snapshot->snapshot, target, indices, count);
  lua_createtable(L, (int)count, 1);
  for (uint32_t i = 0; i < count; i++) { AnvilMarkdownVaultNoteView note; anvil_markdown_vault_note_at(snapshot->snapshot, indices[i], &note); push_markdown_vault_note(L, &note); lua_rawseti(L, -2, (int)i + 1); }
  lua_pushinteger(L, total); lua_setfield(L, -2, "total"); SDL_free(indices); return 1;
}

static bool lua_contains_ci(const char *text, const char *query) {
  if (!query || !query[0]) return true;
  size_t qlen = strlen(query);
  for (const char *start = text ? text : ""; *start; start++) {
    size_t i = 0;
    while (i < qlen && start[i] && SDL_tolower((unsigned char)start[i]) == SDL_tolower((unsigned char)query[i])) i++;
    if (i == qlen) return true;
  }
  return false;
}

static char *lua_strip_markdown_extension(const char *path) {
  size_t len = strlen(path); const char *dot = strrchr(path, '.');
  if (dot && (SDL_strcasecmp(dot, ".md") == 0 || SDL_strcasecmp(dot, ".markdown") == 0 || SDL_strcasecmp(dot, ".mdown") == 0)) len = (size_t)(dot - path);
  char *copy = (char *)SDL_malloc(len + 1); if (!copy) return NULL; memcpy(copy, path, len); copy[len] = '\0'; return copy;
}

static char *lua_relative_markdown_target(const char *source_path, const char *target_path) {
  char *source = SDL_strdup(source_path ? source_path : ""), *target = SDL_strdup(target_path ? target_path : "");
  if (!source || !target) { SDL_free(source); SDL_free(target); return NULL; }
  for (char *c = source; *c; c++) if (*c == '\\') *c = '/';
  for (char *c = target; *c; c++) if (*c == '\\') *c = '/';
  char *slash = strrchr(source, '/'); if (slash) *slash = '\0';
  size_t common = 0, last_separator = 0; bool target_inside_source = false;
  while (source[common] && target[common] && SDL_tolower((unsigned char)source[common]) == SDL_tolower((unsigned char)target[common])) {
    if (source[common] == '/') last_separator = common + 1;
    common++;
  }
  if (!source[common] && target[common] == '/') { last_separator = common + 1; target_inside_source = true; }
  size_t ups = 0; for (size_t i = last_separator; source[i]; i++) if (source[i] == '/') ups++;
  if (!target_inside_source && source[last_separator]) ups++;
  const char *remainder = target + last_separator;
  size_t bytes = ups * 3 + strlen(remainder) + 3;
  char *result = (char *)SDL_calloc(bytes, 1);
  if (result) {
    for (size_t i = 0; i < ups; i++) strcat(result, "../");
    strcat(result, remainder);
    char *without = lua_strip_markdown_extension(result);
    if (without) { SDL_free(result); result = without; }
    if (!strchr(result, '/') && strncmp(result, "..", 2) != 0) {
      char *local = (char *)SDL_malloc(strlen(result) + 3); if (local) { strcpy(local, "./"); strcat(local, result); SDL_free(result); result = local; }
    }
  }
  SDL_free(source); SDL_free(target); return result;
}

static char *markdown_completion_note_target(AnvilMarkdownVaultSnapshot *snapshot,
  const AnvilMarkdownVaultNoteView *note, const char *policy, const char *source_path) {
  char *rel = lua_strip_markdown_extension(note->relative_path);
  if (!rel) return NULL;
  if (policy && strcmp(policy, "root") == 0) return rel;
  if (policy && strcmp(policy, "relative") == 0 && source_path && source_path[0]) {
    SDL_free(rel); return lua_relative_markdown_target(source_path, note->absolute_path);
  }
  uint32_t matches[2];
  uint32_t count = anvil_markdown_vault_resolve_notes(snapshot, note->display_name, matches, 2);
  if (count == 1) { SDL_free(rel); return SDL_strdup(note->display_name); }
  count = anvil_markdown_vault_resolve_notes(snapshot, rel, matches, 2);
  if (count == 1) return rel;
  SDL_free(rel); return SDL_strdup(note->relative_path);
}

static void push_completion_candidate(lua_State *L, const char *text, const char *target, const char *kind,
  const char *path, const char *rel_path, uint32_t line, const char *info) {
  lua_createtable(L, 0, 7);
  lua_pushstring(L, text); lua_setfield(L, -2, "text"); lua_pushstring(L, target); lua_setfield(L, -2, "target");
  lua_pushstring(L, kind); lua_setfield(L, -2, "kind"); lua_pushstring(L, path); lua_setfield(L, -2, "path");
  lua_pushstring(L, rel_path); lua_setfield(L, -2, "rel_path"); lua_pushinteger(L, line); lua_setfield(L, -2, "line");
  lua_pushstring(L, info ? info : rel_path); lua_setfield(L, -2, "info");
}

static int markdown_vault_completion(lua_State *L) {
  LuaMarkdownVaultSnapshot *lua_snapshot = check_markdown_vault_snapshot(L, 1);
  AnvilMarkdownVaultSnapshot *snapshot = lua_snapshot->snapshot;
  const char *mode = luaL_checkstring(L, 2), *query = luaL_optstring(L, 3, ""), *source = luaL_optstring(L, 4, "");
  const char *policy = luaL_optstring(L, 5, "shortest_unique");
  uint32_t requested_limit = (uint32_t)luaL_optinteger(L, 6, 200);
  if (!requested_limit) requested_limit = 1;
  if (requested_limit > 4096) requested_limit = 4096;
  (void)requested_limit;
  uint32_t limit = 4096; /* bounded superset; Lua applies deterministic ordering and the requested limit */
  lua_createtable(L, (int)limit, 0); uint32_t out = 0;
  uint32_t source_index = 0; bool has_source = source[0] && anvil_markdown_vault_note_lookup(snapshot, source, &source_index);
  uint32_t candidate_indices[4096], candidate_count = 0;
  if ((strcmp(mode, "current_heading") == 0 || strcmp(mode, "current_block") == 0) && has_source) {
    candidate_indices[0] = source_index; candidate_count = 1;
  } else {
    AnvilMarkdownVaultCompletionKind kind = strcmp(mode, "note") == 0 ? ANVIL_MARKDOWN_VAULT_COMPLETION_NOTES
      : (strcmp(mode, "global_heading") == 0 ? ANVIL_MARKDOWN_VAULT_COMPLETION_HEADINGS : ANVIL_MARKDOWN_VAULT_COMPLETION_BLOCKS);
    uint32_t total = anvil_markdown_vault_completion_candidates(snapshot, kind, query, 0, NULL, 0);
    candidate_count = total < 4096 ? total : 4096;
    anvil_markdown_vault_completion_candidates(snapshot, kind, query, 0, candidate_indices, candidate_count);
  }
  for (uint32_t candidate = 0; out < limit && candidate < candidate_count; candidate++) {
    uint32_t i = candidate_indices[candidate];
    AnvilMarkdownVaultNoteView note; if (!anvil_markdown_vault_note_at(snapshot, i, &note)) continue;
    bool current = has_source && i == source_index;
    if (strcmp(mode, "note") == 0) {
      char *target = markdown_completion_note_target(snapshot, &note, policy, source);
      if (target && (lua_contains_ci(note.display_name, query) || lua_contains_ci(target, query) || lua_contains_ci(note.relative_path, query))) {
        push_completion_candidate(L, note.display_name, target, "note", note.absolute_path, note.relative_path, 1, note.relative_path); lua_rawseti(L, -2, ++out);
      }
      for (uint32_t a = 0; target && out < limit && a < note.alias_count; a++) if (lua_contains_ci(note.aliases[a], query)) {
        size_t bytes = strlen(target) + strlen(note.aliases[a]) + 2; char *alias_target = (char *)SDL_malloc(bytes);
        if (alias_target) { SDL_snprintf(alias_target, bytes, "%s|%s", target, note.aliases[a]); push_completion_candidate(L, note.aliases[a], alias_target, "alias", note.absolute_path, note.relative_path, 1, note.relative_path); lua_rawseti(L, -2, ++out); SDL_free(alias_target); }
      }
      SDL_free(target);
    } else if ((strcmp(mode, "current_heading") == 0 && current) || strcmp(mode, "global_heading") == 0) {
      char *note_target = markdown_completion_note_target(snapshot, &note, policy, source);
      for (uint32_t h = 0; note_target && out < limit && h < note.heading_count; h++) {
        const AnvilMarkdownVaultHeadingView *heading = &note.headings[h]; const char *heading_text = heading->path_text[0] ? heading->path_text : heading->text;
        if (!lua_contains_ci(heading_text, query)) continue;
        size_t bytes = strlen(note_target) + strlen(heading_text) + 2; char *target = (char *)SDL_malloc(bytes);
        if (!target) continue;
        if (strcmp(mode, "current_heading") == 0) SDL_snprintf(target, bytes, "#%s", heading_text);
        else SDL_snprintf(target, bytes, "%s#%s", note_target, heading_text);
        push_completion_candidate(L, heading_text, target, "heading", note.absolute_path, note.relative_path, heading->line, note.relative_path); lua_rawseti(L, -2, ++out); SDL_free(target);
      }
      SDL_free(note_target);
    } else if ((strcmp(mode, "current_block") == 0 && current) || strcmp(mode, "global_block") == 0) {
      char *note_target = markdown_completion_note_target(snapshot, &note, policy, source);
      for (uint32_t b = 0; note_target && out < limit && b < note.block_count; b++) {
        const AnvilMarkdownVaultBlockView *block = &note.blocks[b]; if (!lua_contains_ci(block->id, query)) continue;
        size_t bytes = strlen(note_target) + strlen(block->id) + 3; char *target = (char *)SDL_malloc(bytes); if (!target) continue;
        if (strcmp(mode, "current_block") == 0) SDL_snprintf(target, bytes, "^%s", block->id);
        else SDL_snprintf(target, bytes, "%s#^%s", note_target, block->id);
        push_completion_candidate(L, block->id, target, "block", note.absolute_path, note.relative_path, block->line, note.relative_path); lua_rawseti(L, -2, ++out); SDL_free(target);
      }
      SDL_free(note_target);
    }
  }
  if (strcmp(mode, "note") == 0) {
    uint32_t total = anvil_markdown_vault_completion_candidates(
      snapshot, ANVIL_MARKDOWN_VAULT_COMPLETION_ATTACHMENTS, query, 0, NULL, 0
    );
    candidate_count = total < 4096 ? total : 4096;
    anvil_markdown_vault_completion_candidates(
      snapshot, ANVIL_MARKDOWN_VAULT_COMPLETION_ATTACHMENTS, query, 0, candidate_indices, candidate_count
    );
  }
  if (strcmp(mode, "note") == 0) for (uint32_t candidate = 0; out < limit && candidate < candidate_count; candidate++) {
    uint32_t i = candidate_indices[candidate];
    AnvilMarkdownVaultAttachmentView entry; if (!anvil_markdown_vault_attachment_at(snapshot, i, &entry)) continue;
    if (lua_contains_ci(entry.display_name, query) || lua_contains_ci(entry.relative_path, query)) {
      push_completion_candidate(L, entry.display_name, entry.relative_path, "attachment", entry.absolute_path, entry.relative_path, 1, entry.relative_path); lua_rawseti(L, -2, ++out);
    }
  }
  return 1;
}

static int treesitter_index_result_adopt_project(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  lua_Integer raw_id = luaL_checkinteger(L, 2);
  luaL_argcheck(L, raw_id > 0, 2, "invalid native Project builder id");
  const char *fingerprint = "";
  bool usage_complete = true;
  if (lua_istable(L, 3)) {
    fingerprint = opt_string_field(L, 3, "fingerprint", "");
    lua_getfield(L, 3, "usage_complete");
    if (!lua_isnil(L, -1)) usage_complete = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
  }
  AnvilTSProjectBuilder *builder = anvil_ts_project_builder_open((uint64_t)raw_id);
  if (!builder) return luaL_error(L, "native Project builder is unavailable");
  AnvilTSProjectFileResult *file = anvil_worker_treesitter_index_result_take_project_file(result->result);
  if (!file) {
    anvil_ts_project_builder_release(builder);
    return luaL_error(L, "native Tree-sitter result has no transferable Project file");
  }
  char *error = NULL;
  bool adopted = anvil_ts_project_builder_adopt(builder, file, fingerprint, usage_complete, &error);
  anvil_ts_project_builder_release(builder);
  if (!adopted) {
    anvil_ts_project_file_free(file);
    lua_pushstring(L, error ? error : "native Project adoption failed");
    free(error);
    return lua_error(L);
  }
  free(error);
  lua_pushboolean(L, 1);
  return 1;
}

static int project_builder_id(lua_State *L) {
  LuaProjectBuilder *builder = check_project_builder(L, 1);
  lua_pushinteger(L, (lua_Integer)anvil_ts_project_builder_id(builder->builder));
  return 1;
}

static int project_builder_remove(lua_State *L) {
  LuaProjectBuilder *builder = check_project_builder(L, 1);
  const char *path = luaL_checkstring(L, 2);
  lua_pushboolean(L, anvil_ts_project_builder_remove(builder->builder, path));
  return 1;
}

static int project_builder_make_snapshot(lua_State *L, bool freeze) {
  LuaProjectBuilder *builder = check_project_builder(L, 1);
  const char *status = freeze ? "ready" : "partial";
  if (lua_istable(L, 2)) status = opt_string_field(L, 2, "status", status);
  char *error = NULL;
  AnvilTSProjectSnapshot *snapshot = anvil_ts_project_builder_snapshot(builder->builder, status, freeze, &error);
  if (!snapshot) {
    lua_pushstring(L, error ? error : "native Project snapshot failed");
    free(error);
    return lua_error(L);
  }
  free(error);
  push_project_snapshot(L, snapshot);
  return 1;
}

static int project_builder_snapshot(lua_State *L) { return project_builder_make_snapshot(L, false); }
static int project_builder_freeze(lua_State *L) { return project_builder_make_snapshot(L, true); }

static int project_builder_gc(lua_State *L) {
  LuaProjectBuilder *builder = (LuaProjectBuilder *)luaL_checkudata(L, 1, API_TYPE_PROJECT_BUILDER);
  if (builder && builder->builder) {
    AnvilTSProjectBuilder *native_builder = builder->builder;
    builder->builder = NULL;
    anvil_ts_project_builder_close(native_builder);
  }
  return 0;
}

static int project_snapshot_summary(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  AnvilTSProjectSnapshotSummary summary;
  anvil_ts_project_snapshot_summary(snapshot->snapshot, &summary);
  lua_createtable(L, 0, 6);
  lua_pushstring(L, summary.status ? summary.status : "failed"); lua_setfield(L, -2, "status");
  lua_pushinteger(L, summary.files); lua_setfield(L, -2, "files");
  lua_pushinteger(L, summary.symbols); lua_setfield(L, -2, "symbols");
  lua_pushinteger(L, summary.usages); lua_setfield(L, -2, "usages");
  lua_pushinteger(L, summary.usage_names); lua_setfield(L, -2, "usage_names");
  lua_pushboolean(L, summary.usage_truncated); lua_setfield(L, -2, "usage_truncated");
  lua_pushboolean(L, summary.usage_complete); lua_setfield(L, -2, "usage_complete");
  return 1;
}

static int project_snapshot_gc(lua_State *L) {
  LuaProjectSnapshot *snapshot = (LuaProjectSnapshot *)luaL_checkudata(L, 1, API_TYPE_PROJECT_SNAPSHOT);
  if (snapshot && snapshot->snapshot) {
    anvil_ts_project_snapshot_release(snapshot->snapshot);
    snapshot->snapshot = NULL;
  }
  return 0;
}

static void project_page_options(lua_State *L, int table, uint32_t *offset, uint32_t *limit) {
  *offset = 1;
  *limit = 256;
  if (lua_istable(L, table)) {
    *offset = opt_uint32_field(L, table, "offset", 1);
    *limit = opt_uint32_field(L, table, "limit", 256);
    luaL_argcheck(L, *limit <= PROJECT_RECORD_PAGE_LIMIT, table, "Project record page limit exceeds 4096");
  }
  if (*offset == 0) *offset = 1;
}

static int project_snapshot_symbols(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  uint32_t offset, limit;
  project_page_options(L, 2, &offset, &limit);
  AnvilTSProjectSnapshotSummary summary;
  anvil_ts_project_snapshot_summary(snapshot->snapshot, &summary);
  uint32_t start = offset - 1;
  if (start > summary.symbols) start = summary.symbols;
  uint32_t out_count = limit < summary.symbols - start ? limit : summary.symbols - start;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; i++) {
    AnvilTSProjectFileResult *file = NULL;
    uint32_t file_index = 0;
    anvil_ts_project_snapshot_symbol_at(snapshot->snapshot, start + i, &file, &file_index);
    push_snapshot_symbol(L, file, file_index);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, start + out_count + 1); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, summary.symbols); lua_setfield(L, -2, "total");
  return 1;
}

static int project_snapshot_usages(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  uint32_t offset, limit;
  project_page_options(L, 2, &offset, &limit);
  AnvilTSProjectSnapshotSummary summary;
  anvil_ts_project_snapshot_summary(snapshot->snapshot, &summary);
  uint32_t start = offset - 1;
  if (start > summary.usages) start = summary.usages;
  uint32_t out_count = limit < summary.usages - start ? limit : summary.usages - start;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; i++) {
    AnvilTSProjectFileResult *file = NULL;
    uint32_t file_index = 0;
    anvil_ts_project_snapshot_usage_at(snapshot->snapshot, start + i, &file, &file_index);
    push_snapshot_usage(L, file, file_index);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, start + out_count + 1); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, summary.usages); lua_setfield(L, -2, "total");
  return 1;
}

static int project_query_string_compare(const void *left, const void *right) {
  const char *const *a = (const char *const *)left;
  const char *const *b = (const char *const *)right;
  return strcmp(*a ? *a : "", *b ? *b : "");
}

static const char **project_query_string_array(lua_State *L, int opts, const char *field, uint32_t *count) {
  *count = 0;
  if (!lua_istable(L, opts)) return NULL;
  lua_getfield(L, opts, field);
  if (lua_isnil(L, -1)) { lua_pop(L, 1); return NULL; }
  luaL_checktype(L, -1, LUA_TTABLE);
  size_t length = lua_rawlen(L, -1);
  luaL_argcheck(L, length <= 65536, opts, "Project query filter exceeds 65536 items");
  for (size_t i = 0; i < length; i++) {
    lua_rawgeti(L, -1, (lua_Integer)i + 1);
    luaL_checktype(L, -1, LUA_TSTRING);
    lua_pop(L, 1);
  }
  const char **items = length ? (const char **)malloc(length * sizeof(*items)) : NULL;
  if (length && !items) luaL_error(L, "out of memory reading native Project query filter");
  for (size_t i = 0; i < length; i++) {
    lua_rawgeti(L, -1, (lua_Integer)i + 1);
    items[i] = lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  if (length > 1) qsort(items, length, sizeof(*items), project_query_string_compare);
  *count = (uint32_t)length;
  return items;
}

static int project_snapshot_query_symbols(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  const char *query = luaL_optstring(L, 2, "");
  uint32_t offset = 0, limit = 200;
  if (lua_istable(L, 3)) {
    offset = opt_uint32_field(L, 3, "offset", 0);
    limit = opt_uint32_field(L, 3, "limit", 200);
    luaL_argcheck(L, limit <= PROJECT_RECORD_PAGE_LIMIT, 3, "Project query limit exceeds 4096");
  }
  uint32_t kind_count = 0, parent_name_count = 0, language_count = 0, excluded_path_count = 0, included_path_count = 0;
  const char **kinds = project_query_string_array(L, 3, "kinds", &kind_count);
  const char **parent_names = project_query_string_array(L, 3, "parent_names", &parent_name_count);
  const char **languages = project_query_string_array(L, 3, "languages", &language_count);
  const char **excluded_paths = project_query_string_array(L, 3, "excluded_paths", &excluded_path_count);
  const char **included_paths = project_query_string_array(L, 3, "included_paths", &included_path_count);
  uint32_t *indices = NULL, count = 0, total = 0;
  bool has_more = false;
  bool ok = anvil_ts_project_snapshot_query_symbols(snapshot->snapshot, query, offset, limit,
    kinds, kind_count, parent_names, parent_name_count, languages, language_count,
    excluded_paths, excluded_path_count, included_paths, included_path_count,
    &indices, &count, &total, &has_more, NULL, NULL);
  free(kinds);
  free(parent_names);
  free(languages);
  free(excluded_paths);
  free(included_paths);
  if (!ok) { free(indices); return luaL_error(L, "native Project symbol query failed"); }
  lua_createtable(L, (int)count, 3);
  for (uint32_t i = 0; i < count; i++) {
    AnvilTSProjectFileResult *file = NULL;
    uint32_t file_index = 0;
    anvil_ts_project_snapshot_symbol_at(snapshot->snapshot, indices[i], &file, &file_index);
    push_snapshot_symbol(L, file, file_index);
    lua_rawseti(L, -2, (int)i + 1);
  }
  free(indices);
  lua_pushinteger(L, offset + count); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, total); lua_setfield(L, -2, "total");
  lua_pushboolean(L, has_more); lua_setfield(L, -2, "has_more");
  return 1;
}

static int project_snapshot_query_usages(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  size_t name_len = 0;
  const char *name = luaL_checklstring(L, 2, &name_len);
  luaL_argcheck(L, name_len <= UINT32_MAX, 2, "Project usage name exceeds uint32 range");
  uint32_t offset = 0, limit = 500;
  bool include_declarations = true;
  if (lua_istable(L, 3)) {
    offset = opt_uint32_field(L, 3, "offset", 0);
    limit = opt_uint32_field(L, 3, "limit", 500);
    luaL_argcheck(L, limit <= PROJECT_RECORD_PAGE_LIMIT, 3, "Project query limit exceeds 4096");
    lua_getfield(L, 3, "include_declaration");
    if (!lua_isnil(L, -1)) include_declarations = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
  }
  uint32_t excluded_path_count = 0, included_path_count = 0;
  const char **excluded_paths = project_query_string_array(L, 3, "excluded_paths", &excluded_path_count);
  const char **included_paths = project_query_string_array(L, 3, "included_paths", &included_path_count);
  uint32_t *indices = NULL, count = 0, total = 0;
  bool has_more = false;
  bool ok = anvil_ts_project_snapshot_query_usages(snapshot->snapshot, name, (uint32_t)name_len,
    offset, limit, include_declarations, excluded_paths, excluded_path_count,
    included_paths, included_path_count, &indices, &count, &total, &has_more);
  free(excluded_paths);
  free(included_paths);
  if (!ok) { free(indices); return luaL_error(L, "native Project usage query failed"); }
  lua_createtable(L, (int)count, 3);
  for (uint32_t i = 0; i < count; i++) {
    AnvilTSProjectFileResult *file = NULL;
    uint32_t file_index = 0;
    anvil_ts_project_snapshot_usage_at(snapshot->snapshot, indices[i], &file, &file_index);
    push_snapshot_usage(L, file, file_index);
    lua_rawseti(L, -2, (int)i + 1);
  }
  free(indices);
  lua_pushinteger(L, offset + count); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, total); lua_setfield(L, -2, "total");
  lua_pushboolean(L, has_more); lua_setfield(L, -2, "has_more");
  return 1;
}

static int project_snapshot_files(lua_State *L) {
  LuaProjectSnapshot *snapshot = check_project_snapshot(L, 1);
  uint32_t offset, limit;
  project_page_options(L, 2, &offset, &limit);
  AnvilTSProjectSnapshotSummary summary;
  anvil_ts_project_snapshot_summary(snapshot->snapshot, &summary);
  uint32_t start = offset - 1;
  if (start > summary.files) start = summary.files;
  uint32_t out_count = limit < summary.files - start ? limit : summary.files - start;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; i++) {
    AnvilTSProjectSnapshotFileView view;
    anvil_ts_project_snapshot_file_at(snapshot->snapshot, start + i, &view);
    lua_createtable(L, 0, 8);
    set_project_file_path_fields(L, view.file);
    lua_pushstring(L, view.fingerprint ? view.fingerprint : ""); lua_setfield(L, -2, "fingerprint");
    lua_pushboolean(L, view.usage_complete); lua_setfield(L, -2, "usage_complete");
    lua_pushinteger(L, anvil_ts_project_file_symbol_count(view.file)); lua_setfield(L, -2, "symbol_count");
    lua_pushinteger(L, anvil_ts_project_file_usage_count(view.file)); lua_setfield(L, -2, "usage_count");
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, start + out_count + 1); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, summary.files); lua_setfield(L, -2, "total");
  return 1;
}

static int treesitter_index_result_symbols(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  uint32_t offset, limit;
  project_page_options(L, 2, &offset, &limit);
  uint32_t count = anvil_worker_treesitter_index_result_project_symbol_count(result->result);
  uint32_t start = offset - 1;
  if (start > count) start = count;
  uint32_t out_count = limit < count - start ? limit : count - start;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; i++) {
    push_project_symbol(L, result->result, start + i);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, start + out_count + 1); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, count); lua_setfield(L, -2, "total");
  return 1;
}

static int treesitter_index_result_usages(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  uint32_t offset, limit;
  project_page_options(L, 2, &offset, &limit);
  uint32_t count = anvil_worker_treesitter_index_result_project_usage_count(result->result);
  uint32_t start = offset - 1;
  if (start > count) start = count;
  uint32_t out_count = limit < count - start ? limit : count - start;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; i++) {
    push_project_usage(L, result->result, start + i);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, start + out_count + 1); lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, count); lua_setfield(L, -2, "total");
  return 1;
}

static int treesitter_index_result_captures(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  const char *kind = luaL_optstring(L, 2, "outline");
  uint32_t offset = 1;
  uint32_t limit = 256;
  if (lua_istable(L, 3)) {
    offset = opt_uint32_field(L, 3, "offset", 1);
    limit = opt_uint32_field(L, 3, "limit", 256);
  } else if (!lua_isnoneornil(L, 3)) {
    lua_Integer raw = luaL_checkinteger(L, 3);
    luaL_argcheck(L, raw >= 0 && raw <= UINT32_MAX, 3, "limit out of range");
    limit = (uint32_t)raw;
  }
  if (offset == 0) offset = 1;
  uint32_t count = anvil_worker_treesitter_index_result_capture_count(result->result, kind);
  uint32_t start = offset - 1;
  if (start > count) start = count;
  uint32_t remaining = count - start;
  uint32_t out_count = limit < remaining ? limit : remaining;
  lua_createtable(L, (int)out_count, 0);
  for (uint32_t i = 0; i < out_count; ++i) {
    push_treesitter_capture(L, result->result, kind, start + i);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_pushinteger(L, (lua_Integer)(start + out_count + 1));
  lua_setfield(L, -2, "next_offset");
  lua_pushinteger(L, (lua_Integer)count);
  lua_setfield(L, -2, "total");
  return 1;
}

static int treesitter_index_result_captures_for_lines(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  const char *kind = luaL_optstring(L, 2, "outline");
  lua_Integer raw_line1 = luaL_checkinteger(L, 3);
  lua_Integer raw_line2 = luaL_checkinteger(L, 4);
  luaL_argcheck(L, raw_line1 > 0 && raw_line1 <= UINT32_MAX, 3, "invalid start line");
  luaL_argcheck(L, raw_line2 >= raw_line1 && raw_line2 <= UINT32_MAX, 4, "invalid end line");
  uint32_t line1 = (uint32_t)raw_line1;
  uint32_t line2 = (uint32_t)raw_line2;
  uint32_t limit = lua_istable(L, 5) ? opt_uint32_field(L, 5, "limit", 4096) : 4096;
  uint32_t *indices = limit > 0 ? (uint32_t *)SDL_malloc(sizeof(*indices) * limit) : NULL;
  if (limit > 0 && !indices) return luaL_error(L, "out of memory querying Tree-sitter line captures");
  uint32_t matches = anvil_worker_treesitter_index_result_captures_for_lines(
    result->result, kind, line1, line2, indices, limit
  );
  uint32_t emitted = matches < limit ? matches : limit;
  lua_createtable(L, (int)emitted, 2);
  for (uint32_t i = 0; i < emitted; i++) {
    push_treesitter_capture(L, result->result, kind, indices[i]);
    lua_rawseti(L, -2, (int)i + 1);
  }
  SDL_free(indices);
  lua_pushinteger(L, (lua_Integer)matches);
  lua_setfield(L, -2, "total");
  lua_pushboolean(L, matches > emitted);
  lua_setfield(L, -2, "truncated");
  return 1;
}

typedef struct {
  const char *name;
  uint32_t name_len;
  uint32_t start_byte, end_byte;
  uint32_t start_line, start_col, end_line, end_col;
  uint64_t node_id;
} SemanticCaptureView;

typedef struct {
  SemanticCaptureView capture;
} SemanticNodeView;

typedef struct {
  uint32_t start_byte, end_byte, prefix_max_end;
} SemanticInterval;

static bool capture_view_at(
  AnvilWorkerTreeSitterIndexResult *result, const char *kind, uint32_t index,
  SemanticCaptureView *out
) {
  int32_t priority = 0;
  uint32_t match_id = 0, pattern_index = 0, capture_index = 0, order = 0;
  return anvil_worker_treesitter_index_result_capture_at(
    result, kind, index, &out->name, &out->name_len,
    &out->start_byte, &out->end_byte, &out->start_line, &out->start_col,
    &out->end_line, &out->end_col, &priority, &match_id, &pattern_index,
    &capture_index, &order, &out->node_id
  );
}

static bool capture_name_equal(const SemanticCaptureView *capture, const char *name) {
  size_t len = strlen(name);
  return capture->name_len == len && memcmp(capture->name, name, len) == 0;
}

static bool capture_name_prefix(const SemanticCaptureView *capture, const char *prefix) {
  size_t len = strlen(prefix);
  return capture->name_len >= len && memcmp(capture->name, prefix, len) == 0;
}

static bool semantic_parent(const SemanticCaptureView *capture) {
  return capture_name_prefix(capture, "block.") || capture_name_prefix(capture, "span.");
}

static bool semantic_decoration(const SemanticCaptureView *capture) {
  return capture_name_prefix(capture, "marker.") || capture_name_prefix(capture, "content.");
}

static bool extension_parent(const SemanticCaptureView *capture) {
  return capture_name_equal(capture, "span.wiki_link")
    || capture_name_equal(capture, "span.embed")
    || capture_name_equal(capture, "span.comment")
    || capture_name_equal(capture, "span.tag");
}

static bool extension_capture_native(const SemanticCaptureView *capture) {
  return capture_name_equal(capture, "span.wiki_link")
    || capture_name_equal(capture, "span.embed")
    || capture_name_equal(capture, "span.highlight")
    || capture_name_equal(capture, "span.comment")
    || capture_name_equal(capture, "span.tag")
    || capture_name_prefix(capture, "marker.wiki_")
    || capture_name_prefix(capture, "marker.embed_")
    || capture_name_prefix(capture, "marker.highlight_")
    || capture_name_prefix(capture, "marker.comment_")
    || capture_name_equal(capture, "content.target")
    || capture_name_equal(capture, "content.alias")
    || capture_name_equal(capture, "content.highlight")
    || capture_name_equal(capture, "content.comment")
    || capture_name_equal(capture, "content.tag");
}

static bool capture_contains(
  const SemanticCaptureView *outer, const SemanticCaptureView *inner
) {
  return outer->start_byte <= inner->start_byte && outer->end_byte >= inner->end_byte;
}

static int semantic_interval_compare(const void *left_raw, const void *right_raw) {
  const SemanticInterval *left = (const SemanticInterval *)left_raw;
  const SemanticInterval *right = (const SemanticInterval *)right_raw;
  if (left->start_byte < right->start_byte) return -1;
  if (left->start_byte > right->start_byte) return 1;
  if (left->end_byte < right->end_byte) return -1;
  if (left->end_byte > right->end_byte) return 1;
  return 0;
}

static uint32_t build_semantic_intervals(
  SemanticCaptureView *captures, uint32_t capture_count,
  bool comments_only, SemanticInterval *intervals
) {
  uint32_t count = 0;
  for (uint32_t index = 0; index < capture_count; index++) {
    SemanticCaptureView *capture = &captures[index];
    if (!extension_parent(capture)
      || (comments_only && !capture_name_equal(capture, "span.comment")))
      continue;
    intervals[count++] = (SemanticInterval) {
      .start_byte = capture->start_byte,
      .end_byte = capture->end_byte,
      .prefix_max_end = 0,
    };
  }
  qsort(intervals, count, sizeof(*intervals), semantic_interval_compare);
  uint32_t max_end = 0;
  for (uint32_t index = 0; index < count; index++) {
    if (intervals[index].end_byte > max_end) max_end = intervals[index].end_byte;
    intervals[index].prefix_max_end = max_end;
  }
  return count;
}

static bool semantic_interval_contains(
  const SemanticInterval *intervals, uint32_t count,
  const SemanticCaptureView *capture
) {
  uint32_t low = 0, high = count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (intervals[middle].start_byte <= capture->start_byte) low = middle + 1;
    else high = middle;
  }
  return low > 0 && intervals[low - 1].prefix_max_end >= capture->end_byte;
}

static int semantic_node_compare(const void *left_raw, const void *right_raw) {
  const SemanticNodeView *left = (const SemanticNodeView *)left_raw;
  const SemanticNodeView *right = (const SemanticNodeView *)right_raw;
  if (left->capture.start_byte < right->capture.start_byte) return -1;
  if (left->capture.start_byte > right->capture.start_byte) return 1;
  if (left->capture.end_byte < right->capture.end_byte) return -1;
  if (left->capture.end_byte > right->capture.end_byte) return 1;
  size_t common_len = left->capture.name_len < right->capture.name_len
    ? left->capture.name_len : right->capture.name_len;
  int name_order = memcmp(left->capture.name, right->capture.name, common_len);
  if (name_order != 0) return name_order;
  return left->capture.name_len < right->capture.name_len ? -1
    : left->capture.name_len > right->capture.name_len ? 1 : 0;
}

static void push_semantic_range(lua_State *L, const SemanticCaptureView *capture) {
  lua_createtable(L, 0, 6);
  lua_pushinteger(L, capture->start_line); lua_setfield(L, -2, "line1");
  lua_pushinteger(L, capture->start_col); lua_setfield(L, -2, "col1");
  lua_pushinteger(L, capture->end_line); lua_setfield(L, -2, "line2");
  lua_pushinteger(L, capture->end_col); lua_setfield(L, -2, "col2");
  lua_pushinteger(L, capture->start_byte); lua_setfield(L, -2, "start_byte");
  lua_pushinteger(L, capture->end_byte); lua_setfield(L, -2, "end_byte");
}

static void push_canonical_capture_suffix(
  lua_State *L, const SemanticCaptureView *capture, size_t skip
) {
  luaL_Buffer buffer;
  luaL_buffinit(L, &buffer);
  for (size_t index = skip; index < capture->name_len; index++)
    luaL_addchar(&buffer, capture->name[index] == '.' ? '_' : capture->name[index]);
  luaL_pushresult(&buffer);
}

static bool same_semantic_node(
  const SemanticNodeView *node, const SemanticCaptureView *capture
) {
  return node->capture.start_byte == capture->start_byte
    && node->capture.end_byte == capture->end_byte
    && node->capture.name_len == capture->name_len
    && memcmp(node->capture.name, capture->name, capture->name_len) == 0;
}

static int treesitter_index_result_semantic_nodes_for_lines(lua_State *L) {
  LuaTreeSitterIndexResult *lua_result = check_treesitter_index_result(L, 1);
  AnvilWorkerTreeSitterIndexResult *result = lua_result->result;
  const char *requested = luaL_optstring(L, 2, "both");
  lua_Integer raw_line1 = luaL_checkinteger(L, 3);
  lua_Integer raw_line2 = luaL_checkinteger(L, 4);
  luaL_argcheck(L, raw_line1 > 0 && raw_line1 <= UINT32_MAX, 3, "invalid start line");
  luaL_argcheck(L, raw_line2 >= raw_line1 && raw_line2 <= UINT32_MAX, 4, "invalid end line");
  uint32_t limit = lua_istable(L, 5) ? opt_uint32_field(L, 5, "limit", 4096) : 4096;
  const char *kinds[2];
  uint32_t kind_count = 0;
  if (strcmp(requested, "block") == 0 || strcmp(requested, "outline") == 0) {
    kinds[kind_count++] = "outline";
  } else if (strcmp(requested, "inline") == 0 || strcmp(requested, "usage") == 0) {
    kinds[kind_count++] = "usage";
  } else {
    kinds[kind_count++] = "outline";
    kinds[kind_count++] = "usage";
  }

  uint32_t capacity = limit > 0 ? limit : 1;
  uint32_t *indices = (uint32_t *)SDL_malloc(sizeof(*indices) * capacity);
  SemanticCaptureView *captures = (SemanticCaptureView *)SDL_malloc(sizeof(*captures) * capacity);
  SemanticNodeView *nodes = (SemanticNodeView *)SDL_malloc(sizeof(*nodes) * capacity);
  if (!indices || !captures || !nodes) {
    SDL_free(indices); SDL_free(captures); SDL_free(nodes);
    return luaL_error(L, "out of memory normalizing Markdown semantic nodes");
  }
  uint32_t capture_count = 0, total = 0;
  bool truncated = false;
  for (uint32_t kind_index = 0; kind_index < kind_count; kind_index++) {
    uint32_t remaining = capture_count < limit ? limit - capture_count : 0;
    uint32_t matches = anvil_worker_treesitter_index_result_captures_for_lines(
      result, kinds[kind_index], (uint32_t)raw_line1, (uint32_t)raw_line2,
      indices, remaining
    );
    total += matches;
    uint32_t emitted = matches < remaining ? matches : remaining;
    for (uint32_t index = 0; index < emitted; index++) {
      if (capture_view_at(result, kinds[kind_index], indices[index], &captures[capture_count]))
        capture_count++;
    }
    if (matches > emitted) truncated = true;
  }

  /* Suppress CommonMark captures nested inside first-party extension spans. */
  bool has_inline = kind_count == 2 || strcmp(kinds[0], "usage") == 0;
  if (has_inline) {
    SemanticInterval *extension_intervals = (SemanticInterval *)SDL_malloc(
      sizeof(*extension_intervals) * (capture_count > 0 ? capture_count : 1)
    );
    SemanticInterval *comment_intervals = (SemanticInterval *)SDL_malloc(
      sizeof(*comment_intervals) * (capture_count > 0 ? capture_count : 1)
    );
    if (!extension_intervals || !comment_intervals) {
      SDL_free(extension_intervals); SDL_free(comment_intervals);
      SDL_free(indices); SDL_free(captures); SDL_free(nodes);
      return luaL_error(L, "out of memory indexing Markdown extension spans");
    }
    uint32_t extension_count = build_semantic_intervals(
      captures, capture_count, false, extension_intervals
    );
    uint32_t comment_count = build_semantic_intervals(
      captures, capture_count, true, comment_intervals
    );
    for (uint32_t index = 0; index < capture_count; index++) {
      SemanticCaptureView *capture = &captures[index];
      if (extension_capture_native(capture)) continue;
      bool any_extension = capture_name_equal(capture, "span.link_reference")
        || capture_name_prefix(capture, "content.link");
      if (semantic_interval_contains(
          any_extension ? extension_intervals : comment_intervals,
          any_extension ? extension_count : comment_count, capture
      )) {
        capture->name = NULL;
        capture->name_len = 0;
      }
    }
    SDL_free(extension_intervals);
    SDL_free(comment_intervals);
  }

  uint32_t node_count = 0;
  for (uint32_t index = 0; index < capture_count; index++) {
    SemanticCaptureView *capture = &captures[index];
    if (!capture->name || !semantic_parent(capture)) continue;
    nodes[node_count++].capture = *capture;
  }
  qsort(nodes, node_count, sizeof(*nodes), semantic_node_compare);
  uint32_t unique_count = 0;
  for (uint32_t index = 0; index < node_count; index++) {
    if (unique_count == 0 || !same_semantic_node(&nodes[unique_count - 1], &nodes[index].capture))
      nodes[unique_count++] = nodes[index];
  }
  node_count = unique_count;

  lua_createtable(L, (int)node_count, 2);
  int result_table = lua_gettop(L);
  for (uint32_t index = 0; index < node_count; index++) {
    SemanticCaptureView *capture = &nodes[index].capture;
    lua_createtable(L, 0, 8);
    char id_suffix[32];
    SDL_snprintf(id_suffix, sizeof(id_suffix), ":%llu",
      (unsigned long long)capture->node_id);
    luaL_Buffer id_buffer;
    luaL_buffinit(L, &id_buffer);
    luaL_addlstring(&id_buffer, capture->name, capture->name_len);
    luaL_addstring(&id_buffer, id_suffix);
    luaL_pushresult(&id_buffer);
    lua_setfield(L, -2, "id");
    push_canonical_capture_suffix(L, capture, capture_name_prefix(capture, "block.") ? 6 : 5);
    lua_setfield(L, -2, "type");
    push_semantic_range(L, capture); lua_setfield(L, -2, "source");
    lua_createtable(L, 2, 0); lua_setfield(L, -2, "marker_ranges");
    lua_createtable(L, 2, 0); lua_setfield(L, -2, "content_ranges");
    lua_createtable(L, 0, 4); lua_setfield(L, -2, "attributes");
    lua_pushstring(L, "complete"); lua_setfield(L, -2, "confidence");
    lua_rawseti(L, result_table, (int)index + 1);
  }

  for (uint32_t capture_index = 0; capture_index < capture_count; capture_index++) {
    SemanticCaptureView *decoration = &captures[capture_index];
    if (!decoration->name || !semantic_decoration(decoration)) continue;
    int best = -1;
    uint32_t best_size = UINT32_MAX;
    bool target_or_alias = capture_name_equal(decoration, "content.target")
      || capture_name_equal(decoration, "content.alias");
    uint32_t low = 0, high = node_count;
    while (low < high) {
      uint32_t middle = low + (high - low) / 2;
      if (nodes[middle].capture.start_byte <= decoration->start_byte) low = middle + 1;
      else high = middle;
    }
    for (uint32_t reverse = low; reverse > 0; reverse--) {
      uint32_t node_index = reverse - 1;
      SemanticCaptureView *parent = &nodes[node_index].capture;
      if (best >= 0 && parent->start_byte < nodes[best].capture.start_byte) break;
      if (!capture_contains(parent, decoration)) continue;
      bool family_match = true;
      if (capture_name_prefix(decoration, "marker.wiki_")
        || capture_name_prefix(decoration, "content.wiki_"))
        family_match = capture_name_equal(parent, "span.wiki_link");
      else if (capture_name_prefix(decoration, "marker.embed_")
        || capture_name_prefix(decoration, "content.embed_"))
        family_match = capture_name_equal(parent, "span.embed");
      else if (capture_name_prefix(decoration, "marker.highlight")
        || capture_name_prefix(decoration, "content.highlight"))
        family_match = capture_name_equal(parent, "span.highlight");
      else if (capture_name_prefix(decoration, "marker.comment")
        || capture_name_prefix(decoration, "content.comment"))
        family_match = capture_name_equal(parent, "span.comment");
      if (target_or_alias)
        family_match = capture_name_equal(parent, "span.wiki_link")
          || capture_name_equal(parent, "span.embed");
      uint32_t size = parent->end_byte - parent->start_byte;
      if (family_match && size < best_size) { best = (int)node_index; best_size = size; }
    }
    if (best < 0) continue;
    lua_rawgeti(L, result_table, best + 1);
    const char *range_field = capture_name_prefix(decoration, "marker.")
      ? "marker_ranges" : "content_ranges";
    lua_getfield(L, -1, range_field);
    size_t range_count = lua_rawlen(L, -1);
    push_semantic_range(L, decoration);
    lua_rawseti(L, -2, (int)range_count + 1);
    lua_pop(L, 1);
    const char *dot = memchr(decoration->name, '.', decoration->name_len);
    if (dot && (size_t)(dot - decoration->name + 1) < decoration->name_len) {
      lua_getfield(L, -1, "attributes");
      push_semantic_range(L, decoration);
      SemanticCaptureView suffix = *decoration;
      size_t skip = (size_t)(dot - decoration->name + 1);
      push_canonical_capture_suffix(L, &suffix, skip);
      lua_insert(L, -2);
      lua_settable(L, -3);
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_pushinteger(L, total); lua_setfield(L, result_table, "total");
  lua_pushboolean(L, truncated); lua_setfield(L, result_table, "truncated");
  SDL_free(indices); SDL_free(captures); SDL_free(nodes);
  return 1;
}

static void push_result(lua_State *L, AnvilWorkerResult *result) {
  lua_createtable(L, 0, 8);
  lua_pushinteger(L, (lua_Integer)anvil_worker_result_job_id(result));
  lua_setfield(L, -2, "job_id");
  lua_pushstring(L, anvil_worker_result_kind(result));
  lua_setfield(L, -2, "kind");
  lua_pushstring(L, anvil_worker_result_type(result));
  lua_setfield(L, -2, "type");
  const char *value = anvil_worker_result_value(result);
  if (value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, "value");
    lua_createtable(L, 0, 1);
    lua_pushstring(L, value);
    lua_setfield(L, -2, "value");
    lua_setfield(L, -2, "payload");
  }
  AnvilWorkerTreeSitterIndexResult *treesitter_result = anvil_worker_result_steal_treesitter_index_result(result);
  if (treesitter_result) {
    push_treesitter_index_result_handle(L, treesitter_result);
    lua_setfield(L, -2, "result");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) {
      lua_pop(L, 1);
      lua_createtable(L, 0, 1);
    }
    lua_getfield(L, -2, "result");
    lua_setfield(L, -2, "result");
    lua_setfield(L, -2, "payload");
  }
  if (anvil_worker_result_has_project_symbol_query(result)) {
    uint32_t query_count = anvil_worker_result_project_symbol_query_count(result);
    lua_createtable(L, (int)query_count, 3);
    for (uint32_t i = 0; i < query_count; i++) {
      AnvilTSProjectFileResult *file = NULL;
      uint32_t file_symbol_index = 0;
      if (anvil_worker_result_project_symbol_query_at(result, i, &file, &file_symbol_index)) {
        push_snapshot_symbol(L, file, file_symbol_index);
      } else {
        lua_pushnil(L);
      }
      lua_rawseti(L, -2, (int)i + 1);
    }
    lua_pushinteger(L, anvil_worker_result_project_symbol_query_total(result));
    lua_setfield(L, -2, "total");
    lua_pushboolean(L, anvil_worker_result_project_symbol_query_has_more(result));
    lua_setfield(L, -2, "has_more");
    lua_pushnumber(L, anvil_worker_result_project_symbol_query_ms(result));
    lua_setfield(L, -2, "query_ms");
    lua_setfield(L, -2, "symbols");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 1); }
    lua_getfield(L, -2, "symbols");
    lua_setfield(L, -2, "symbols");
    lua_setfield(L, -2, "payload");
  }
  AnvilTSProjectSnapshot *project_snapshot = anvil_worker_result_steal_project_snapshot(result);
  if (project_snapshot) {
    push_project_snapshot(L, project_snapshot);
    lua_setfield(L, -2, "snapshot");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) {
      lua_pop(L, 1);
      lua_createtable(L, 0, 1);
    }
    lua_getfield(L, -2, "snapshot");
    lua_setfield(L, -2, "snapshot");
    lua_setfield(L, -2, "payload");
  }
  AnvilGitStatusSnapshot *git_status_snapshot = anvil_worker_result_steal_git_status_snapshot(result);
  if (git_status_snapshot) {
    push_git_status_snapshot(L, git_status_snapshot);
    lua_setfield(L, -2, "snapshot");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 1); }
    lua_getfield(L, -2, "snapshot");
    lua_setfield(L, -2, "snapshot");
    lua_setfield(L, -2, "payload");
  }
  AnvilProjectFileManifestSnapshot *manifest = anvil_worker_result_steal_project_file_manifest(result);
  if (manifest) {
    push_manifest_handle(L, manifest);
    lua_setfield(L, -2, "manifest");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 1); }
    lua_getfield(L, -2, "manifest"); lua_setfield(L, -2, "manifest");
    lua_setfield(L, -2, "payload");
  }
  AnvilMarkdownVaultSnapshot *vault_snapshot = anvil_worker_result_steal_markdown_vault_snapshot(result);
  if (vault_snapshot) {
    push_markdown_vault_handle(L, vault_snapshot); lua_setfield(L, -2, "vault_snapshot");
    lua_getfield(L, -1, "payload"); if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 1); }
    lua_getfield(L, -2, "vault_snapshot"); lua_setfield(L, -2, "vault_snapshot"); lua_setfield(L, -2, "payload");
  }
  const char *error = anvil_worker_result_error(result);
  if (error) {
    lua_pushstring(L, error);
    lua_setfield(L, -2, "error");
  }
  uint32_t files_completed = anvil_worker_result_files_completed(result);
  uint32_t files_skipped = anvil_worker_result_files_skipped(result);
  uint32_t files_reused = anvil_worker_result_files_reused(result);
  uint32_t symbols_found = anvil_worker_result_symbols_found(result);
  uint32_t usages_found = anvil_worker_result_usages_found(result);
  double batch_total_ms = anvil_worker_result_batch_total_ms(result);
  if (files_completed || files_skipped || files_reused || symbols_found || usages_found || batch_total_ms > 0.0) {
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 4); }
    lua_pushinteger(L, files_completed); lua_setfield(L, -2, "files_completed");
    lua_pushinteger(L, files_skipped); lua_setfield(L, -2, "files_skipped");
    lua_pushinteger(L, anvil_worker_result_invalid_text_files_skipped(result));
    lua_setfield(L, -2, "invalid_text_files_skipped");
    lua_pushinteger(L, anvil_worker_result_io_files_skipped(result));
    lua_setfield(L, -2, "io_files_skipped");
    lua_pushinteger(L, anvil_worker_result_parse_files_skipped(result));
    lua_setfield(L, -2, "parse_files_skipped");
    const char *first_skipped_path = anvil_worker_result_first_skipped_path(result);
    const char *first_skipped_reason = anvil_worker_result_first_skipped_reason(result);
    if (first_skipped_path) {
      lua_pushstring(L, first_skipped_path);
      lua_setfield(L, -2, "first_skipped_path");
    }
    if (first_skipped_reason) {
      lua_pushstring(L, first_skipped_reason);
      lua_setfield(L, -2, "first_skipped_reason");
    }
    lua_pushinteger(L, files_reused); lua_setfield(L, -2, "files_reused");
    lua_pushinteger(L, symbols_found); lua_setfield(L, -2, "symbols_found");
    lua_pushinteger(L, usages_found); lua_setfield(L, -2, "usages_found");
    lua_pushnumber(L, batch_total_ms); lua_setfield(L, -2, "batch_total_ms");
    lua_pushnumber(L, anvil_worker_result_batch_parse_ms(result)); lua_setfield(L, -2, "batch_parse_ms");
    lua_pushnumber(L, anvil_worker_result_batch_project_record_ms(result)); lua_setfield(L, -2, "batch_project_record_ms");
    lua_pushnumber(L, anvil_worker_result_project_builder_ms(result)); lua_setfield(L, -2, "project_builder_ms");
    lua_pushnumber(L, anvil_worker_result_project_snapshot_ms(result)); lua_setfield(L, -2, "project_snapshot_ms");
    lua_setfield(L, -2, "payload");
  }
  int index = anvil_worker_result_index(result);
  if (index != 0) {
    lua_pushinteger(L, index);
    lua_setfield(L, -2, "index");
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) {
      lua_pop(L, 1);
      lua_createtable(L, 0, 1);
    }
    lua_pushinteger(L, index);
    lua_setfield(L, -2, "index");
    lua_setfield(L, -2, "payload");
  }
  if (anvil_worker_result_cancelled(result)) {
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "cancelled");
  }
}

static int pool_drain(lua_State *L) {
  LuaWorkerPool *pool = check_pool(L, 1);
  int max_messages = 64;
  if (lua_istable(L, 2)) {
    max_messages = opt_int_field(L, 2, "max_messages", 64);
  } else if (!lua_isnoneornil(L, 2)) {
    max_messages = (int)luaL_checkinteger(L, 2);
  }
  if (max_messages < 0) max_messages = 0;
  lua_createtable(L, max_messages, 0);
  int count = 0;
  while (count < max_messages) {
    AnvilWorkerResult *result = anvil_worker_pool_pop_result(pool->pool);
    if (!result) break;
    push_result(L, result);
    lua_rawseti(L, -2, ++count);
    anvil_worker_result_free(result);
  }
  return 1;
}

static int pool_shutdown(lua_State *L) {
  LuaWorkerPool *pool = (LuaWorkerPool *)luaL_checkudata(L, 1, API_TYPE_WORKER_POOL);
  if (pool && pool->pool) {
    bool cancel_running = true;
    if (lua_istable(L, 2)) {
      lua_getfield(L, 2, "cancel_running");
      if (!lua_isnil(L, -1)) cancel_running = lua_toboolean(L, -1) != 0;
      lua_pop(L, 1);
    }
    anvil_worker_pool_destroy(pool->pool, cancel_running);
    pool->pool = NULL;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int pool_diagnostics(lua_State *L) {
  LuaWorkerPool *pool = check_pool(L, 1);
  lua_createtable(L, 0, 6);
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_worker_count(pool->pool));
  lua_setfield(L, -2, "worker_count");
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_submitted_count(pool->pool));
  lua_setfield(L, -2, "submitted");
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_completed_count(pool->pool));
  lua_setfield(L, -2, "completed");
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_cancelled_count(pool->pool));
  lua_setfield(L, -2, "cancelled");
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_failed_count(pool->pool));
  lua_setfield(L, -2, "failed");
  lua_pushinteger(L, (lua_Integer)anvil_worker_pool_result_count(pool->pool));
  lua_setfield(L, -2, "result_count");
  return 1;
}

static int job_status(lua_State *L) {
  LuaWorkerJob *job = check_job(L, 1);
  push_status(L, job->job);
  return 1;
}

static int job_cancel_requested(lua_State *L) {
  LuaWorkerJob *job = check_job(L, 1);
  lua_pushboolean(L, anvil_worker_job_cancel_requested(job->job));
  return 1;
}

static void push_cancel_token(lua_State *L, AnvilWorkerCancelToken *token) {
  LuaWorkerCancelToken *lua_token = (LuaWorkerCancelToken *)lua_newuserdata(L, sizeof(*lua_token));
  lua_token->token = token;
  luaL_getmetatable(L, API_TYPE_WORKER_CANCEL_TOKEN);
  lua_setmetatable(L, -2);
}

static int token_name(lua_State *L) {
  LuaWorkerCancelToken *token = check_cancel_token(L, 1);
  lua_pushstring(L, anvil_worker_cancel_token_name(token->token));
  return 1;
}

static int token_cancel(lua_State *L) {
  LuaWorkerCancelToken *token = check_cancel_token(L, 1);
  anvil_worker_cancel_token_cancel(token->token);
  lua_pushboolean(L, 1);
  return 1;
}

static int token_cancelled(lua_State *L) {
  LuaWorkerCancelToken *token = check_cancel_token(L, 1);
  lua_pushboolean(L, anvil_worker_cancel_token_cancelled(token->token));
  return 1;
}

static int f_new_cancel_token(lua_State *L) {
  const char *name = luaL_optstring(L, 1, NULL);
  AnvilWorkerCancelToken *token = anvil_worker_cancel_token_create(name);
  if (!token) return luaL_error(L, "failed to create native worker cancel token");
  push_cancel_token(L, token);
  return 1;
}

static int f_open_cancel_token(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  AnvilWorkerCancelToken *token = anvil_worker_cancel_token_open(name);
  if (!token) {
    lua_pushnil(L);
    lua_pushstring(L, "cancel token not found");
    return 2;
  }
  push_cancel_token(L, token);
  return 1;
}

static int f_new_project_builder(lua_State *L) {
  uint32_t usage_cap = 750000;
  AnvilTSProjectSnapshot *base_snapshot = NULL;
  if (lua_istable(L, 1)) {
    usage_cap = opt_uint32_field(L, 1, "usage_cap", usage_cap);
    lua_getfield(L, 1, "base_snapshot");
    if (!lua_isnil(L, -1)) base_snapshot = check_project_snapshot(L, -1)->snapshot;
    lua_pop(L, 1);
  }
  AnvilTSProjectBuilder *native_builder = base_snapshot
    ? anvil_ts_project_builder_create_from_snapshot(base_snapshot, usage_cap)
    : anvil_ts_project_builder_create(usage_cap);
  if (!native_builder) return luaL_error(L, "failed to create native Project builder");
  LuaProjectBuilder *builder = (LuaProjectBuilder *)lua_newuserdata(L, sizeof(*builder));
  builder->builder = native_builder;
  luaL_getmetatable(L, API_TYPE_PROJECT_BUILDER);
  lua_setmetatable(L, -2);
  return 1;
}

static int f_new(lua_State *L) {
  int worker_count = 0;
  const char *name = "native-worker-pool";
  if (lua_istable(L, 1)) {
    worker_count = opt_int_field(L, 1, "worker_count", 0);
    name = opt_string_field(L, 1, "name", name);
  }
  if (worker_count <= 0) {
    int cpus = SDL_GetNumLogicalCPUCores();
    worker_count = cpus > 0 ? cpus : 1;
    if (worker_count > 4) worker_count = 4;
  }
  AnvilWorkerPool *native_pool = anvil_worker_pool_create(name, worker_count);
  if (!native_pool) return luaL_error(L, "failed to create native worker pool");
  LuaWorkerPool *pool = (LuaWorkerPool *)lua_newuserdata(L, sizeof(*pool));
  pool->pool = native_pool;
  luaL_getmetatable(L, API_TYPE_WORKER_POOL);
  lua_setmetatable(L, -2);
  return 1;
}

static const luaL_Reg pool_methods[] = {
  { "submit", pool_submit },
  { "cancel", pool_cancel },
  { "status", pool_status },
  { "drain", pool_drain },
  { "shutdown", pool_shutdown },
  { "diagnostics", pool_diagnostics },
  { "__gc", pool_gc },
  { NULL, NULL }
};

static const luaL_Reg job_methods[] = {
  { "status", job_status },
  { "cancel_requested", job_cancel_requested },
  { "__gc", job_gc },
  { NULL, NULL }
};

static const luaL_Reg cancel_token_methods[] = {
  { "name", token_name },
  { "cancel", token_cancel },
  { "cancelled", token_cancelled },
  { "__gc", cancel_token_gc },
  { NULL, NULL }
};

static const luaL_Reg treesitter_index_result_methods[] = {
  { "summary", treesitter_index_result_summary },
  { "adopt_project", treesitter_index_result_adopt_project },
  { "symbols", treesitter_index_result_symbols },
  { "usages", treesitter_index_result_usages },
  { "captures", treesitter_index_result_captures },
  { "captures_for_lines", treesitter_index_result_captures_for_lines },
  { "semantic_nodes_for_lines", treesitter_index_result_semantic_nodes_for_lines },
  { "close", treesitter_index_result_close },
  { "__gc", treesitter_index_result_gc },
  { NULL, NULL }
};

static const luaL_Reg project_builder_methods[] = {
  { "id", project_builder_id },
  { "snapshot", project_builder_snapshot },
  { "freeze", project_builder_freeze },
  { "remove", project_builder_remove },
  { "close", project_builder_gc },
  { "__gc", project_builder_gc },
  { NULL, NULL }
};

static const luaL_Reg project_snapshot_methods[] = {
  { "summary", project_snapshot_summary },
  { "close", project_snapshot_gc },
  { "files", project_snapshot_files },
  { "symbols", project_snapshot_symbols },
  { "usages", project_snapshot_usages },
  { "query_symbols", project_snapshot_query_symbols },
  { "query_usages", project_snapshot_query_usages },
  { "__gc", project_snapshot_gc },
  { NULL, NULL }
};

static const luaL_Reg git_status_snapshot_methods[] = {
  { "summary", git_status_snapshot_summary },
  { "lookup", git_status_snapshot_lookup },
  { "close", git_status_snapshot_close },
  { "__gc", git_status_snapshot_close },
  { NULL, NULL }
};

static const luaL_Reg project_file_manifest_methods[] = {
  { "summary", project_file_manifest_summary },
  { "page", project_file_manifest_page },
  { "lookup", project_file_manifest_lookup },
  { "close", project_file_manifest_close },
  { "__gc", project_file_manifest_close },
  { NULL, NULL }
};

static const luaL_Reg markdown_vault_snapshot_methods[] = {
  { "summary", markdown_vault_summary },
  { "note", markdown_vault_note },
  { "attachment", markdown_vault_attachment },
  { "resolve_notes", markdown_vault_resolve_notes_lua },
  { "resolve_attachments", markdown_vault_resolve_attachments_lua },
  { "linked_notes", markdown_vault_linked_notes_lua },
  { "completion", markdown_vault_completion },
  { "close", markdown_vault_close },
  { "__gc", markdown_vault_close },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "new", f_new },
  { "new_project_builder", f_new_project_builder },
  { "new_cancel_token", f_new_cancel_token },
  { "open_cancel_token", f_open_cancel_token },
  { NULL, NULL }
};

int luaopen_worker_pool_native(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_WORKER_POOL);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, pool_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_WORKER_JOB);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, job_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_WORKER_CANCEL_TOKEN);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, cancel_token_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_TREESITTER_INDEX_RESULT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, treesitter_index_result_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_PROJECT_BUILDER);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, project_builder_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_PROJECT_SNAPSHOT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, project_snapshot_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_GIT_STATUS_SNAPSHOT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, git_status_snapshot_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_PROJECT_FILE_MANIFEST);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, project_file_manifest_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_MARKDOWN_VAULT_SNAPSHOT);
  lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, markdown_vault_snapshot_methods, 0); lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
