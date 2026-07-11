#include "api.h"
#include "../worker_pool.h"

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define API_TYPE_WORKER_POOL "NativeWorkerPool"
#define API_TYPE_WORKER_JOB "NativeWorkerJob"
#define API_TYPE_WORKER_CANCEL_TOKEN "NativeWorkerCancelToken"
#define API_TYPE_TREESITTER_INDEX_RESULT "NativeTreeSitterIndexResult"

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
  spec.language = opt_string_field(L, 2, "language", NULL);
  spec.text = opt_string_field(L, 2, "text", NULL);
  spec.outline_query = opt_string_field(L, 2, "outline_query", NULL);
  spec.usage_query = opt_string_field(L, 2, "usage_query", NULL);
  spec.cancel_token = opt_string_field(L, 2, "cancel_token", NULL);
  spec.parse_timeout_ms = opt_uint32_field(L, 2, "parse_timeout_ms", 0);
  spec.query_timeout_ms = opt_uint32_field(L, 2, "query_timeout_ms", 0);
  spec.match_limit = opt_uint32_field(L, 2, "match_limit", 0);
  spec.max_captures = opt_uint32_field(L, 2, "max_captures", 0);
  spec.usage_query_timeout_ms = opt_uint32_field(L, 2, "usage_query_timeout_ms", 0);
  spec.usage_match_limit = opt_uint32_field(L, 2, "usage_match_limit", 0);
  spec.usage_max_captures = opt_uint32_field(L, 2, "usage_max_captures", 0);
  lua_getfield(L, 2, "previous_result");
  if (!lua_isnil(L, -1)) {
    LuaTreeSitterIndexResult *previous = check_treesitter_index_result(L, -1);
    spec.previous_result = previous->result;
  }
  lua_pop(L, 1);
  char *error = NULL;
  AnvilWorkerJob *job = anvil_worker_pool_submit(pool->pool, &spec, &error);
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

static int treesitter_index_result_summary(lua_State *L) {
  LuaTreeSitterIndexResult *result = check_treesitter_index_result(L, 1);
  lua_createtable(L, 0, 6);
  lua_pushstring(L, anvil_worker_treesitter_index_result_language(result->result));
  lua_setfield(L, -2, "language");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_byte_len(result->result));
  lua_setfield(L, -2, "byte_len");
  lua_pushinteger(L, (lua_Integer)anvil_worker_treesitter_index_result_line_count(result->result));
  lua_setfield(L, -2, "line_count");
  lua_createtable(L, 0, 16);
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
  lua_setfield(L, -2, "metrics");
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
    const char *error = anvil_worker_treesitter_index_result_error(result->result, kind);
    if (error) {
      lua_pushstring(L, error);
      lua_setfield(L, -2, "error");
    }
    lua_setfield(L, -2, kind);
  }
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
  { "captures", treesitter_index_result_captures },
  { "captures_for_lines", treesitter_index_result_captures_for_lines },
  { "close", treesitter_index_result_close },
  { "__gc", treesitter_index_result_gc },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "new", f_new },
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

  luaL_newlib(L, lib);
  return 1;
}
