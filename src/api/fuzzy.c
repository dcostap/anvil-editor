#include "api.h"
#include "../fuzzy.h"

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <SDL3/SDL.h>

#define API_TYPE_FUZZY_INDEX "FuzzyIndex"
#define API_TYPE_FUZZY_FILE_BUILDER "FuzzyFileIndexBuilder"
#define API_TYPE_FUZZY_FILE_INDEX "FuzzyFileIndex"
#define API_TYPE_FUZZY_FILE_BUILD_TASK "FuzzyFileIndexBuildTask"
#define FUZZY_MAX_RETURN_SPANS 256

typedef struct {
  FuzzyIndex index;
} LuaFuzzyIndex;

typedef struct {
  FuzzyFileIndexBuilder *builder;
} LuaFuzzyFileIndexBuilder;

typedef struct {
  FuzzyFileIndex *index;
} LuaFuzzyFileIndex;

typedef struct {
  FuzzyFileIndexBuilder *builder;
  FuzzyFileIndex *index;
  FuzzyFileIndexStats stats;
  SDL_Thread *thread;
  SDL_AtomicInt done;
  bool consumed;
} LuaFuzzyFileBuildTask;

static FuzzyMode opt_mode(lua_State *L, int opts_index) {
  FuzzyMode mode = FUZZY_MODE_GENERIC;
  if (opts_index != 0 && lua_istable(L, opts_index)) {
    lua_getfield(L, opts_index, "mode");
    if (!lua_isnil(L, -1)) mode = fuzzy_mode_from_string(luaL_checkstring(L, -1));
    lua_pop(L, 1);
  }
  return mode;
}

static uint32_t opt_limit(lua_State *L, int opts_index, uint32_t def) {
  uint32_t limit = def;
  if (opts_index != 0 && lua_istable(L, opts_index)) {
    lua_getfield(L, opts_index, "limit");
    if (!lua_isnil(L, -1)) {
      lua_Integer n = luaL_checkinteger(L, -1);
      limit = n > 0 ? (uint32_t)n : 0;
    }
    lua_pop(L, 1);
  }
  return limit;
}

static bool opt_spans(lua_State *L, int opts_index) {
  bool spans = false;
  if (opts_index != 0 && lua_istable(L, opts_index)) {
    lua_getfield(L, opts_index, "spans");
    spans = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
  }
  return spans;
}

static const char **read_string_items(lua_State *L, int table_index, uint32_t *out_count) {
  luaL_checktype(L, table_index, LUA_TTABLE);
  size_t len = lua_rawlen(L, table_index);
  if (len > UINT32_MAX) luaL_error(L, "too many fuzzy items");
  uint32_t count = (uint32_t)len;
  const char **items = count ? (const char **)calloc(count, sizeof(char *)) : NULL;
  if (count && !items) luaL_error(L, "out of memory");

  for (uint32_t i = 0; i < count; ++i) {
    lua_rawgeti(L, table_index, i + 1);
    items[i] = luaL_checkstring(L, -1);
    lua_pop(L, 1);
  }

  if (out_count) *out_count = count;
  return items;
}

static void build_index_from_lua(lua_State *L, int table_index, FuzzyMode mode, FuzzyIndex *index) {
  uint32_t count = 0;
  const char **items = read_string_items(L, table_index, &count);
  bool ok = fuzzy_index_build(index, items, count, mode);
  free(items);
  if (!ok) luaL_error(L, "failed to build fuzzy index");
}

static LuaFuzzyIndex *check_index(lua_State *L, int idx) {
  return (LuaFuzzyIndex *)luaL_checkudata(L, idx, API_TYPE_FUZZY_INDEX);
}

static LuaFuzzyFileIndexBuilder *check_file_builder(lua_State *L, int idx) {
  return (LuaFuzzyFileIndexBuilder *)luaL_checkudata(L, idx, API_TYPE_FUZZY_FILE_BUILDER);
}

static LuaFuzzyFileIndex *check_file_index(lua_State *L, int idx) {
  return (LuaFuzzyFileIndex *)luaL_checkudata(L, idx, API_TYPE_FUZZY_FILE_INDEX);
}

static LuaFuzzyFileBuildTask *check_file_build_task(lua_State *L, int idx) {
  return (LuaFuzzyFileBuildTask *)luaL_checkudata(L, idx, API_TYPE_FUZZY_FILE_BUILD_TASK);
}

static void push_span_table(lua_State *L, const FuzzySpan *span) {
  lua_createtable(L, 2, 0);
  lua_pushinteger(L, span->start);
  lua_rawseti(L, -2, 1);
  lua_pushinteger(L, span->end);
  lua_rawseti(L, -2, 2);
}

static void push_match_position_fields(lua_State *L, const FuzzySpan *spans, uint32_t count) {
  if (count == 0) return;

  uint32_t match_start = spans[0].start;
  for (uint32_t i = 1; i < count; ++i) {
    if (spans[i].start < match_start) match_start = spans[i].start;
  }
  lua_pushinteger(L, match_start);
  lua_setfield(L, -2, "match_start");

  if (count == 1) {
    push_span_table(L, &spans[0]);
    lua_setfield(L, -2, "selection_span");
  }
}

static void push_spans(lua_State *L, const FuzzyIndex *index, uint32_t entry_index, const char *query, FuzzySpan *spans, uint32_t *out_count) {
  uint32_t count = fuzzy_match_spans(index, entry_index, query, spans, FUZZY_MAX_RETURN_SPANS);
  if (out_count) *out_count = count;
  lua_createtable(L, count, 0);
  for (uint32_t i = 0; i < count; ++i) {
    push_span_table(L, &spans[i]);
    lua_rawseti(L, -2, i + 1);
  }
}

static void push_results(lua_State *L, const FuzzyIndex *index, const char *query, FuzzySearchResult *results, uint32_t count, bool include_spans, bool has_more) {
  lua_createtable(L, count, 1);
  for (uint32_t i = 0; i < count; ++i) {
    FuzzySearchResult *r = &results[i];
    lua_createtable(L, 0, include_spans ? 7 : 4);

    lua_pushinteger(L, r->source_index);
    lua_setfield(L, -2, "index");
    lua_pushstring(L, fuzzy_index_text(index, r->entry_index));
    lua_setfield(L, -2, "text");
    lua_pushinteger(L, r->score);
    lua_setfield(L, -2, "score");
    lua_pushinteger(L, r->entry_index + 1);
    lua_setfield(L, -2, "entry_index");
    if (include_spans) {
      FuzzySpan spans[FUZZY_MAX_RETURN_SPANS];
      uint32_t span_count = 0;
      push_spans(L, index, r->entry_index, query, spans, &span_count);
      lua_setfield(L, -2, "spans");
      push_match_position_fields(L, spans, span_count);
    }

    lua_rawseti(L, -2, i + 1);
  }
  lua_pushboolean(L, has_more);
  lua_setfield(L, -2, "has_more");
}

static int fuzzy_index_gc(lua_State *L) {
  LuaFuzzyIndex *li = check_index(L, 1);
  fuzzy_index_free(&li->index);
  return 0;
}

static int fuzzy_index_free_lua(lua_State *L) {
  return fuzzy_index_gc(L);
}

static int fuzzy_index_set_items(lua_State *L) {
  LuaFuzzyIndex *li = check_index(L, 1);
  FuzzyMode mode = li->index.mode;
  if (lua_istable(L, 3)) mode = opt_mode(L, 3);
  fuzzy_index_free(&li->index);
  build_index_from_lua(L, 2, mode, &li->index);
  return 0;
}

static int fuzzy_index_search_lua(lua_State *L) {
  LuaFuzzyIndex *li = check_index(L, 1);
  const char *query = luaL_optstring(L, 2, "");
  int opts = lua_istable(L, 3) ? 3 : 0;
  uint32_t limit = opt_limit(L, opts, 100);
  bool include_spans = opt_spans(L, opts);
  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *results = fuzzy_index_search(&li->index, query, limit, &count, &has_more);
  if (!results && limit != 0) luaL_error(L, "out of memory");
  push_results(L, &li->index, query, results, count, include_spans, has_more);
  free(results);
  return 1;
}

static int fuzzy_index_len(lua_State *L) {
  LuaFuzzyIndex *li = check_index(L, 1);
  lua_pushinteger(L, li->index.count);
  return 1;
}

static int f_index(lua_State *L) {
  FuzzyMode mode = opt_mode(L, 2);
  LuaFuzzyIndex *li = (LuaFuzzyIndex *)lua_newuserdata(L, sizeof(LuaFuzzyIndex));
  memset(li, 0, sizeof(*li));
  luaL_getmetatable(L, API_TYPE_FUZZY_INDEX);
  lua_setmetatable(L, -2);
  build_index_from_lua(L, 1, mode, &li->index);
  return 1;
}

static const char *required_table_string(lua_State *L, int table_index, const char *field) {
  lua_getfield(L, table_index, field);
  const char *value = luaL_checkstring(L, -1);
  lua_pop(L, 1);
  return value;
}

static int32_t optional_table_int(lua_State *L, int table_index, const char *field, int32_t fallback) {
  lua_getfield(L, table_index, field);
  int32_t value = lua_isnil(L, -1) ? fallback : (int32_t)luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  return value;
}

static int f_file_index_builder(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  uint32_t root_count = (uint32_t)lua_rawlen(L, 1);
  luaL_argcheck(L, root_count > 0, 1, "at least one file-index root is required");
  FuzzyFileRootSpec *roots = (FuzzyFileRootSpec *)calloc(root_count, sizeof(*roots));
  FuzzyFilePathMappingSpec **mapping_arrays =
    (FuzzyFilePathMappingSpec **)calloc(root_count, sizeof(*mapping_arrays));
  if (!roots || !mapping_arrays) {
    free(roots);
    free(mapping_arrays);
    return luaL_error(L, "out of memory");
  }

  for (uint32_t i = 0; i < root_count; ++i) {
    lua_rawgeti(L, 1, i + 1);
    int root_table = lua_gettop(L);
    luaL_checktype(L, root_table, LUA_TTABLE);
    roots[i].path = required_table_string(L, root_table, "path");
    roots[i].label = required_table_string(L, root_table, "label");
    roots[i].role = required_table_string(L, root_table, "role");
    roots[i].id = required_table_string(L, root_table, "id");
    roots[i].rank_penalty = optional_table_int(L, root_table, "rank_penalty", 0);
    lua_getfield(L, root_table, "mappings");
    if (lua_istable(L, -1)) {
      uint32_t mapping_count = (uint32_t)lua_rawlen(L, -1);
      roots[i].mapping_count = mapping_count;
      if (mapping_count) {
        mapping_arrays[i] = (FuzzyFilePathMappingSpec *)calloc(mapping_count, sizeof(*mapping_arrays[i]));
        if (!mapping_arrays[i]) {
          for (uint32_t j = 0; j < root_count; ++j) free(mapping_arrays[j]);
          free(mapping_arrays);
          free(roots);
          return luaL_error(L, "out of memory");
        }
        roots[i].mappings = mapping_arrays[i];
      }
      int mappings_table = lua_gettop(L);
      for (uint32_t j = 0; j < mapping_count; ++j) {
        lua_rawgeti(L, mappings_table, j + 1);
        int mapping_table = lua_gettop(L);
        luaL_checktype(L, mapping_table, LUA_TTABLE);
        mapping_arrays[i][j].relative_prefix = required_table_string(L, mapping_table, "relative_prefix");
        mapping_arrays[i][j].label = required_table_string(L, mapping_table, "label");
        mapping_arrays[i][j].role = required_table_string(L, mapping_table, "role");
        mapping_arrays[i][j].id = required_table_string(L, mapping_table, "id");
        mapping_arrays[i][j].rank_penalty = optional_table_int(L, mapping_table, "rank_penalty", 0);
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 2);
  }

  FuzzyFileIndexBuilder *builder = fuzzy_file_index_builder_create(roots, root_count);
  for (uint32_t i = 0; i < root_count; ++i) free(mapping_arrays[i]);
  free(mapping_arrays);
  free(roots);
  if (!builder) return luaL_error(L, "failed to create native file-index builder");
  LuaFuzzyFileIndexBuilder *lua_builder =
    (LuaFuzzyFileIndexBuilder *)lua_newuserdata(L, sizeof(*lua_builder));
  lua_builder->builder = builder;
  luaL_getmetatable(L, API_TYPE_FUZZY_FILE_BUILDER);
  lua_setmetatable(L, -2);
  return 1;
}

static int file_builder_feed(lua_State *L) {
  LuaFuzzyFileIndexBuilder *builder = check_file_builder(L, 1);
  luaL_argcheck(L, builder->builder != NULL, 1, "file-index builder is already finished");
  lua_Integer root = luaL_checkinteger(L, 2);
  luaL_argcheck(L, root > 0 && root <= UINT32_MAX, 2, "root index is out of range");
  size_t len = 0;
  const char *chunk = luaL_checklstring(L, 3, &len);
  if (!fuzzy_file_index_builder_feed(builder->builder, (uint32_t)root - 1, chunk, len)) {
    return luaL_error(L, "native file-index ingestion failed");
  }
  return 0;
}

static int file_builder_gc(lua_State *L) {
  LuaFuzzyFileIndexBuilder *builder = check_file_builder(L, 1);
  fuzzy_file_index_builder_free(builder->builder);
  builder->builder = NULL;
  return 0;
}

static void push_file_index_stats(lua_State *L, const FuzzyFileIndexStats *stats) {
  lua_createtable(L, 0, 4);
  lua_pushinteger(L, stats->candidates); lua_setfield(L, -2, "candidates");
  lua_pushinteger(L, stats->accepted); lua_setfield(L, -2, "accepted");
  lua_pushinteger(L, stats->duplicates); lua_setfield(L, -2, "duplicates");
  lua_pushnumber(L, (lua_Number)stats->input_bytes); lua_setfield(L, -2, "input_bytes");
}

static int SDLCALL file_builder_finish_thread(void *payload) {
  LuaFuzzyFileBuildTask *task = (LuaFuzzyFileBuildTask *)payload;
  task->index = fuzzy_file_index_builder_finish(task->builder, &task->stats);
  task->builder = NULL;
  SDL_SetAtomicInt(&task->done, 1);
  return task->index ? 0 : 1;
}

static int file_builder_finish_async(lua_State *L) {
  LuaFuzzyFileIndexBuilder *builder = check_file_builder(L, 1);
  luaL_argcheck(L, builder->builder != NULL, 1, "file-index builder is already finished");
  LuaFuzzyFileBuildTask *task =
    (LuaFuzzyFileBuildTask *)lua_newuserdata(L, sizeof(*task));
  memset(task, 0, sizeof(*task));
  task->builder = builder->builder;
  builder->builder = NULL;
  luaL_getmetatable(L, API_TYPE_FUZZY_FILE_BUILD_TASK);
  lua_setmetatable(L, -2);
  task->thread = SDL_CreateThread(file_builder_finish_thread,
    "fuzzy-file-index-finish", task);
  if (!task->thread) {
    fuzzy_file_index_builder_free(task->builder);
    task->builder = NULL;
    task->consumed = true;
    return luaL_error(L, "could not start native file-index finalization thread: %s", SDL_GetError());
  }
  return 1;
}

static void push_file_entry_fields(lua_State *L, const FuzzyFileEntryView *entry) {
  lua_pushstring(L, entry->display_path); lua_setfield(L, -2, "text");
  lua_pushstring(L, entry->relative_path); lua_setfield(L, -2, "relative_path");
  lua_pushstring(L, entry->root_path); lua_setfield(L, -2, "root_path");
  lua_pushstring(L, entry->root_label); lua_setfield(L, -2, "root_label");
  lua_pushstring(L, entry->role); lua_setfield(L, -2, "root_role");
  lua_pushstring(L, entry->root_id); lua_setfield(L, -2, "root_id");
  lua_pushinteger(L, entry->rank_penalty); lua_setfield(L, -2, "rank_penalty");
  lua_pushinteger(L, entry->root_index + 1); lua_setfield(L, -2, "root_index");
  if (entry->role && strcmp(entry->role, "root") != 0 && entry->root_label && entry->root_label[0]) {
    lua_createtable(L, 2, 0);
    lua_pushinteger(L, 1); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, (lua_Integer)strlen(entry->root_label)); lua_rawseti(L, -2, 2);
    lua_setfield(L, -2, "prefix_span");
  }
}

static int file_builder_finish(lua_State *L) {
  LuaFuzzyFileIndexBuilder *builder = check_file_builder(L, 1);
  luaL_argcheck(L, builder->builder != NULL, 1, "file-index builder is already finished");
  FuzzyFileIndexStats stats = { 0 };
  FuzzyFileIndex *index = fuzzy_file_index_builder_finish(builder->builder, &stats);
  builder->builder = NULL;
  if (!index) return luaL_error(L, "native file-index finalization failed");
  LuaFuzzyFileIndex *lua_index = (LuaFuzzyFileIndex *)lua_newuserdata(L, sizeof(*lua_index));
  lua_index->index = index;
  luaL_getmetatable(L, API_TYPE_FUZZY_FILE_INDEX);
  lua_setmetatable(L, -2);
  push_file_index_stats(L, &stats);
  return 2;
}

static int file_build_task_poll(lua_State *L) {
  LuaFuzzyFileBuildTask *task = check_file_build_task(L, 1);
  luaL_argcheck(L, !task->consumed, 1, "file-index build result is already consumed");
  if (SDL_GetAtomicInt(&task->done) == 0) return 0;
  if (task->thread) {
    SDL_WaitThread(task->thread, NULL);
    task->thread = NULL;
  }
  if (!task->index) {
    task->consumed = true;
    return luaL_error(L, "native file-index finalization failed");
  }
  LuaFuzzyFileIndex *lua_index = (LuaFuzzyFileIndex *)lua_newuserdata(L, sizeof(*lua_index));
  lua_index->index = task->index;
  task->index = NULL;
  task->consumed = true;
  luaL_getmetatable(L, API_TYPE_FUZZY_FILE_INDEX);
  lua_setmetatable(L, -2);
  push_file_index_stats(L, &task->stats);
  return 2;
}

static int file_build_task_gc(lua_State *L) {
  LuaFuzzyFileBuildTask *task = check_file_build_task(L, 1);
  if (task->thread) {
    SDL_WaitThread(task->thread, NULL);
    task->thread = NULL;
  }
  fuzzy_file_index_builder_free(task->builder);
  fuzzy_file_index_free(task->index);
  task->builder = NULL;
  task->index = NULL;
  task->consumed = true;
  return 0;
}

static int file_index_gc(lua_State *L) {
  LuaFuzzyFileIndex *index = check_file_index(L, 1);
  fuzzy_file_index_free(index->index);
  index->index = NULL;
  return 0;
}

static int file_index_len(lua_State *L) {
  LuaFuzzyFileIndex *index = check_file_index(L, 1);
  lua_pushinteger(L, fuzzy_file_index_count(index->index));
  return 1;
}

static int file_index_entry(lua_State *L) {
  LuaFuzzyFileIndex *index = check_file_index(L, 1);
  lua_Integer number = luaL_checkinteger(L, 2);
  if (number <= 0 || number > UINT32_MAX) return 0;
  FuzzyFileEntryView entry = { 0 };
  if (!fuzzy_file_index_entry_at(index->index, (uint32_t)number - 1, &entry)) return 0;
  lua_createtable(L, 0, 10);
  push_file_entry_fields(L, &entry);
  lua_pushinteger(L, number); lua_setfield(L, -2, "index");
  return 1;
}

static int file_index_search(lua_State *L) {
  LuaFuzzyFileIndex *index = check_file_index(L, 1);
  const char *query = luaL_optstring(L, 2, "");
  int opts = lua_istable(L, 3) ? 3 : 0;
  uint32_t limit = opt_limit(L, opts, 100);
  bool include_spans = opt_spans(L, opts);
  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *results = fuzzy_file_index_search(
    index->index, query, limit, &count, &has_more);
  if (!results && limit != 0) return luaL_error(L, "out of memory");
  lua_createtable(L, count, 1);
  for (uint32_t i = 0; i < count; ++i) {
    FuzzySearchResult *result = &results[i];
    FuzzyFileEntryView entry = { 0 };
    if (!fuzzy_file_index_entry_at(index->index, result->source_index - 1, &entry)) continue;
    lua_createtable(L, 0, include_spans ? 16 : 12);
    push_file_entry_fields(L, &entry);
    lua_pushinteger(L, result->source_index); lua_setfield(L, -2, "index");
    lua_pushinteger(L, result->entry_index + 1); lua_setfield(L, -2, "entry_index");
    lua_pushinteger(L, result->score); lua_setfield(L, -2, "score");
    if (include_spans) {
      FuzzySpan spans[FUZZY_MAX_RETURN_SPANS];
      uint32_t span_count = fuzzy_file_index_match_spans(index->index,
        result->entry_index, query, spans, FUZZY_MAX_RETURN_SPANS);
      lua_createtable(L, span_count, 0);
      for (uint32_t s = 0; s < span_count; ++s) {
        push_span_table(L, &spans[s]);
        lua_rawseti(L, -2, s + 1);
      }
      lua_setfield(L, -2, "spans");
      push_match_position_fields(L, spans, span_count);
    }
    lua_rawseti(L, -2, i + 1);
  }
  free(results);
  lua_pushboolean(L, has_more); lua_setfield(L, -2, "has_more");
  return 1;
}

static int f_filter(lua_State *L) {
  FuzzyMode mode = opt_mode(L, 3);
  FuzzyIndex index;
  build_index_from_lua(L, 1, mode, &index);
  const char *query = luaL_optstring(L, 2, "");
  uint32_t limit = opt_limit(L, 3, index.count);
  bool include_spans = opt_spans(L, 3);
  uint32_t count = 0;
  bool has_more = false;
  FuzzySearchResult *results = fuzzy_index_search(&index, query, limit, &count, &has_more);
  if (!results && limit != 0) {
    fuzzy_index_free(&index);
    luaL_error(L, "out of memory");
  }
  push_results(L, &index, query, results, count, include_spans, has_more);
  free(results);
  fuzzy_index_free(&index);
  return 1;
}

static int match_text(lua_State *L, bool as_table) {
  size_t text_len = 0, query_len = 0;
  const char *text = luaL_checklstring(L, 1, &text_len);
  const char *query = luaL_checklstring(L, 2, &query_len);
  (void)query_len;
  FuzzyMode mode = opt_mode(L, 3);
  bool include_spans = as_table ? opt_spans(L, 3) : false;
  if (text_len > UINT32_MAX) return 0;
  FuzzyMatchBuffer buffer;
  if (!fuzzy_match_buffer_build(&buffer, mode, text, (uint32_t)text_len)) luaL_error(L, "out of memory");
  int boundary_score = 0;
  int score = fuzzy_match_buffer_score_parts(mode, &buffer, query, &boundary_score);
  if (score == INT_MIN) {
    fuzzy_match_buffer_free(&buffer);
    return 0;
  }

  if (!as_table) {
    fuzzy_match_buffer_free(&buffer);
    lua_pushinteger(L, score);
    return 1;
  }

  lua_createtable(L, 0, include_spans ? 5 : 2);
  lua_pushinteger(L, score);
  lua_setfield(L, -2, "score");
  lua_pushinteger(L, boundary_score);
  lua_setfield(L, -2, "boundary_score");
  lua_pushlstring(L, text, text_len);
  lua_setfield(L, -2, "text");
  lua_pushstring(L, fuzzy_match_class_name(
    fuzzy_match_text_class(mode, buffer.lower, buffer.len, query)));
  lua_setfield(L, -2, "match_class");
  if (include_spans) {
    FuzzySpan spans[FUZZY_MAX_RETURN_SPANS];
    uint32_t count = fuzzy_match_buffer_spans(mode, text, (uint32_t)text_len,
      &buffer, query, spans, FUZZY_MAX_RETURN_SPANS);
    lua_createtable(L, count, 0);
    for (uint32_t i = 0; i < count; ++i) {
      push_span_table(L, &spans[i]);
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "spans");
    push_match_position_fields(L, spans, count);
  }
  fuzzy_match_buffer_free(&buffer);
  return 1;
}

static int f_score(lua_State *L) {
  return match_text(L, false);
}

static int f_match(lua_State *L) {
  return match_text(L, true);
}

static const luaL_Reg index_methods[] = {
  { "search", fuzzy_index_search_lua },
  { "set_items", fuzzy_index_set_items },
  { "free", fuzzy_index_free_lua },
  { "__len", fuzzy_index_len },
  { "__gc", fuzzy_index_gc },
  { NULL, NULL }
};

static const luaL_Reg file_builder_methods[] = {
  { "feed", file_builder_feed },
  { "finish", file_builder_finish },
  { "finish_async", file_builder_finish_async },
  { "free", file_builder_gc },
  { "__gc", file_builder_gc },
  { NULL, NULL }
};

static const luaL_Reg file_build_task_methods[] = {
  { "poll", file_build_task_poll },
  { "__gc", file_build_task_gc },
  { NULL, NULL }
};

static const luaL_Reg file_index_methods[] = {
  { "search", file_index_search },
  { "entry", file_index_entry },
  { "free", file_index_gc },
  { "__len", file_index_len },
  { "__gc", file_index_gc },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "filter", f_filter },
  { "index", f_index },
  { "score", f_score },
  { "match", f_match },
  { "file_index_builder", f_file_index_builder },
  { NULL, NULL }
};

int luaopen_fuzzy(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_FUZZY_INDEX);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, index_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_FUZZY_FILE_BUILDER);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, file_builder_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_FUZZY_FILE_INDEX);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, file_index_methods, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_FUZZY_FILE_BUILD_TASK);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, file_build_task_methods, 0);
  lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
