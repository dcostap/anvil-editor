#include "api.h"
#include "../fuzzy.h"

#include <ctype.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define API_TYPE_FUZZY_INDEX "FuzzyIndex"
#define FUZZY_MAX_RETURN_SPANS 256

typedef struct {
  FuzzyIndex index;
} LuaFuzzyIndex;

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
  size_t text_len, query_len;
  const char *text = luaL_checklstring(L, 1, &text_len);
  const char *query = luaL_checklstring(L, 2, &query_len);
  (void)query_len;
  FuzzyMode mode = opt_mode(L, 3);
  bool include_spans = as_table ? opt_spans(L, 3) : false;
  if (text_len > UINT32_MAX) return 0;

  char *lower = (char *)malloc(text_len + 1);
  if (!lower) luaL_error(L, "out of memory");
  for (size_t i = 0; i < text_len; ++i) lower[i] = (char)tolower((unsigned char)text[i]);
  lower[text_len] = '\0';

  uint32_t basename_start = 0;
  if (mode == FUZZY_MODE_PATH) {
    for (size_t i = text_len; i > 0; --i) {
      if (text[i - 1] == '/' || text[i - 1] == '\\') { basename_start = (uint32_t)i; break; }
    }
  }
  int score = fuzzy_match_score(mode, text, lower, (uint32_t)text_len, basename_start, query);
  if (score == INT_MIN) {
    free(lower);
    return 0;
  }

  if (!as_table) {
    free(lower);
    lua_pushinteger(L, score);
    return 1;
  }

  lua_createtable(L, 0, include_spans ? 5 : 2);
  lua_pushinteger(L, score);
  lua_setfield(L, -2, "score");
  lua_pushstring(L, text);
  lua_setfield(L, -2, "text");
  if (include_spans) {
    FuzzySpan spans[FUZZY_MAX_RETURN_SPANS];
    uint32_t count = fuzzy_match_text_spans(lower, (uint32_t)text_len, query, spans, FUZZY_MAX_RETURN_SPANS);
    lua_createtable(L, count, 0);
    for (uint32_t i = 0; i < count; ++i) {
      push_span_table(L, &spans[i]);
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "spans");
    push_match_position_fields(L, spans, count);
  }
  free(lower);
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

static const luaL_Reg lib[] = {
  { "filter", f_filter },
  { "index", f_index },
  { "score", f_score },
  { "match", f_match },
  { NULL, NULL }
};

int luaopen_fuzzy(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_FUZZY_INDEX);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, index_methods, 0);
  lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
