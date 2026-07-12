#include "api.h"
#include "../worker_pool.h"
#include "../treesitter/project_index.h"

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define API_TYPE_WORKER_POOL "NativeWorkerPool"
#define API_TYPE_WORKER_JOB "NativeWorkerJob"
#define API_TYPE_WORKER_CANCEL_TOKEN "NativeWorkerCancelToken"
#define API_TYPE_TREESITTER_INDEX_RESULT "NativeTreeSitterIndexResult"
#define API_TYPE_PROJECT_BUILDER "NativeTreeSitterProjectBuilder"
#define API_TYPE_PROJECT_SNAPSHOT "NativeTreeSitterProjectSnapshot"

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

static int pool_submit(lua_State *L) {
  LuaWorkerPool *pool = check_pool(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  AnvilWorkerJobSpec spec;
  memset(&spec, 0, sizeof(spec));
  spec.kind = opt_string_field(L, 2, "kind", NULL);
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
  spec.parse_timeout_ms = opt_uint32_field(L, 2, "parse_timeout_ms", 0);
  spec.query_timeout_ms = opt_uint32_field(L, 2, "query_timeout_ms", 0);
  spec.match_limit = opt_uint32_field(L, 2, "match_limit", 0);
  spec.max_captures = opt_uint32_field(L, 2, "max_captures", 0);
  spec.usage_query_timeout_ms = opt_uint32_field(L, 2, "usage_query_timeout_ms", 0);
  spec.usage_match_limit = opt_uint32_field(L, 2, "usage_match_limit", 0);
  spec.usage_max_captures = opt_uint32_field(L, 2, "usage_max_captures", 0);
  spec.project_usage_cap = opt_uint32_field(L, 2, "project_usage_cap", 750000);
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
  lua_getfield(L, 2, "project_builder_id");
  if (!lua_isnil(L, -1)) {
    lua_Integer raw_id = luaL_checkinteger(L, -1);
    luaL_argcheck(L, raw_id > 0, 2, "invalid native Project builder id");
    spec.project_builder_id = (uint64_t)raw_id;
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
  char *error = NULL;
  AnvilWorkerJob *job = anvil_worker_pool_submit(pool->pool, &spec, &error);
  SDL_free(project_files);
  if (!job) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "submit failed");
    SDL_free(error);
    return 2;
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

#define PROJECT_RECORD_PAGE_LIMIT 4096u

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
  uint32_t kind_count = 0, excluded_path_count = 0;
  const char **kinds = project_query_string_array(L, 3, "kinds", &kind_count);
  const char **excluded_paths = project_query_string_array(L, 3, "excluded_paths", &excluded_path_count);
  uint32_t *indices = NULL, count = 0, total = 0;
  bool has_more = false;
  bool ok = anvil_ts_project_snapshot_query_symbols(snapshot->snapshot, query, offset, limit,
    kinds, kind_count, excluded_paths, excluded_path_count, &indices, &count, &total, &has_more);
  free(kinds);
  free(excluded_paths);
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
  uint32_t excluded_path_count = 0;
  const char **excluded_paths = project_query_string_array(L, 3, "excluded_paths", &excluded_path_count);
  uint32_t *indices = NULL, count = 0, total = 0;
  bool has_more = false;
  bool ok = anvil_ts_project_snapshot_query_usages(snapshot->snapshot, name, (uint32_t)name_len,
    offset, limit, include_declarations, excluded_paths, excluded_path_count, &indices, &count, &total, &has_more);
  free(excluded_paths);
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
  const char *error = anvil_worker_result_error(result);
  if (error) {
    lua_pushstring(L, error);
    lua_setfield(L, -2, "error");
  }
  uint32_t files_completed = anvil_worker_result_files_completed(result);
  uint32_t files_skipped = anvil_worker_result_files_skipped(result);
  uint32_t symbols_found = anvil_worker_result_symbols_found(result);
  uint32_t usages_found = anvil_worker_result_usages_found(result);
  double batch_total_ms = anvil_worker_result_batch_total_ms(result);
  if (files_completed || files_skipped || symbols_found || usages_found || batch_total_ms > 0.0) {
    lua_getfield(L, -1, "payload");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_createtable(L, 0, 4); }
    lua_pushinteger(L, files_completed); lua_setfield(L, -2, "files_completed");
    lua_pushinteger(L, files_skipped); lua_setfield(L, -2, "files_skipped");
    lua_pushinteger(L, symbols_found); lua_setfield(L, -2, "symbols_found");
    lua_pushinteger(L, usages_found); lua_setfield(L, -2, "usages_found");
    lua_pushnumber(L, batch_total_ms); lua_setfield(L, -2, "batch_total_ms");
    lua_pushnumber(L, anvil_worker_result_batch_parse_ms(result)); lua_setfield(L, -2, "batch_parse_ms");
    lua_pushnumber(L, anvil_worker_result_batch_project_record_ms(result)); lua_setfield(L, -2, "batch_project_record_ms");
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
  { "files", project_snapshot_files },
  { "symbols", project_snapshot_symbols },
  { "usages", project_snapshot_usages },
  { "query_symbols", project_snapshot_query_symbols },
  { "query_usages", project_snapshot_query_usages },
  { "__gc", project_snapshot_gc },
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

  luaL_newlib(L, lib);
  return 1;
}
