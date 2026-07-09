#include "api.h"
#include "../treesitter/languages.h"
#include "../treesitter/service.h"
#include "../treesitter/snapshot.h"
#include "../worker_pool.h"

#include <SDL3/SDL_timer.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef ANVIL_TREE_SITTER_RUNTIME_VERSION
#define ANVIL_TREE_SITTER_RUNTIME_VERSION "0.27.0"
#endif

#define API_TYPE_TREESITTER_QUERY "TreeSitterQuery"
#define API_TYPE_TREESITTER_STATE "TreeSitterDocumentState"

typedef struct {
  TSQuery *query;
  const AnvilTSLanguage *language;
} AnvilTSQueryUserdata;

typedef struct {
  AnvilTSDocumentState *state;
} AnvilTSStateUserdata;

static AnvilTSQueryUserdata *check_query(lua_State *L, int idx) {
  return (AnvilTSQueryUserdata *) luaL_checkudata(L, idx, API_TYPE_TREESITTER_QUERY);
}

static AnvilTSStateUserdata *check_state(lua_State *L, int idx) {
  return (AnvilTSStateUserdata *) luaL_checkudata(L, idx, API_TYPE_TREESITTER_STATE);
}

static char *treesitter_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

static void push_language_version(lua_State *L, const AnvilTSLanguage *language) {
  const TSLanguage *ts_language = anvil_ts_language_ptr(language);
  lua_newtable(L);

  lua_pushinteger(L, ts_language ? (lua_Integer) ts_language_abi_version(ts_language) : 0);
  lua_setfield(L, -2, "abi");

  lua_pushinteger(L, TREE_SITTER_LANGUAGE_VERSION);
  lua_setfield(L, -2, "runtime_abi");

  lua_pushinteger(L, TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION);
  lua_setfield(L, -2, "min_compatible_abi");

  lua_pushboolean(L, ts_language && anvil_ts_language_is_compatible(language));
  lua_setfield(L, -2, "compatible");

  if (language->semantic_version) {
    lua_pushstring(L, language->semantic_version);
    lua_setfield(L, -2, "semantic");
  } else if (ts_language) {
    const TSLanguageMetadata *metadata = ts_language_metadata(ts_language);
    if (metadata) {
      char semantic[32];
      snprintf(
        semantic,
        sizeof(semantic),
        "%u.%u.%u",
        (unsigned) metadata->major_version,
        (unsigned) metadata->minor_version,
        (unsigned) metadata->patch_version
      );
      lua_pushstring(L, semantic);
      lua_setfield(L, -2, "semantic");
    }
  }
}

static int f_runtime_version(lua_State *L) {
  lua_pushstring(L, ANVIL_TREE_SITTER_RUNTIME_VERSION);
  return 1;
}

static int f_runtime_abi_version(lua_State *L) {
  lua_pushinteger(L, TREE_SITTER_LANGUAGE_VERSION);
  return 1;
}

static int f_language_ids(lua_State *L) {
  lua_newtable(L);
  size_t count = anvil_ts_language_count();
  for (size_t i = 0; i < count; i++) {
    const AnvilTSLanguage *language = anvil_ts_language_at(i);
    lua_pushstring(L, language->id);
    lua_rawseti(L, -2, (int) i + 1);
  }
  return 1;
}

static int f_has_language(lua_State *L) {
  const char *id = luaL_checkstring(L, 1);
  const AnvilTSLanguage *language = anvil_ts_language_by_id(id);
  lua_pushboolean(L, language && anvil_ts_language_is_compatible(language));
  return 1;
}

static int f_language_version(lua_State *L) {
  const char *id = luaL_checkstring(L, 1);
  const AnvilTSLanguage *language = anvil_ts_language_by_id(id);
  if (!language) {
    lua_pushnil(L);
    return 1;
  }
  push_language_version(L, language);
  return 1;
}

static int f_compile_query(lua_State *L) {
  const char *language_id = luaL_checkstring(L, 1);
  int source_index = lua_gettop(L) >= 3 ? 3 : 2;
  size_t source_len = 0;
  const char *source = luaL_checklstring(L, source_index, &source_len);

  const AnvilTSLanguage *language = anvil_ts_language_by_id(language_id);
  if (!language || !anvil_ts_language_is_compatible(language)) {
    lua_pushnil(L);
    lua_pushfstring(L, "unknown or incompatible Tree-sitter language '%s'", language_id);
    return 2;
  }

  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(language),
    source,
    (uint32_t) source_len,
    &error_offset,
    &error_type
  );
  if (!query) {
    lua_pushnil(L);
    lua_pushfstring(
      L,
      "Tree-sitter query error %d at byte %d",
      (int) error_type,
      (int) error_offset
    );
    return 2;
  }

  AnvilTSQueryUserdata *userdata = (AnvilTSQueryUserdata *) lua_newuserdata(L, sizeof(*userdata));
  userdata->query = query;
  userdata->language = language;
  luaL_setmetatable(L, API_TYPE_TREESITTER_QUERY);
  return 1;
}

static uint32_t option_uint32(lua_State *L, int idx, const char *field, uint32_t fallback) {
  if (!lua_istable(L, idx)) return fallback;
  lua_getfield(L, idx, field);
  uint32_t value = fallback;
  if (lua_isnumber(L, -1)) {
    lua_Integer raw = lua_tointeger(L, -1);
    if (raw > 0 && raw <= UINT32_MAX) value = (uint32_t) raw;
  }
  lua_pop(L, 1);
  return value;
}

static bool lua_integer_field(lua_State *L, int idx, const char *field, uint32_t *out) {
  lua_getfield(L, idx, field);
  if (!lua_isnumber(L, -1)) {
    lua_pop(L, 1);
    return false;
  }
  lua_Integer raw = lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (raw < 0 || raw > UINT32_MAX) return false;
  *out = (uint32_t) raw;
  return true;
}

static bool edit_from_lua(lua_State *L, int idx, AnvilTSEdit *edit, char **error) {
  if (error) *error = NULL;
  if (!lua_istable(L, idx) || !edit) {
    if (error) *error = treesitter_strdup("Tree-sitter edit must be a table");
    return false;
  }

  uint32_t line1 = 0, col1 = 0, line2 = 0, col2 = 0, start_offset = 0, end_offset = 0;
  if (!lua_integer_field(L, idx, "line1", &line1) || line1 == 0 ||
      !lua_integer_field(L, idx, "col1", &col1) || col1 == 0 ||
      !lua_integer_field(L, idx, "line2", &line2) || line2 == 0 ||
      !lua_integer_field(L, idx, "col2", &col2) || col2 == 0 ||
      !lua_integer_field(L, idx, "start_offset", &start_offset) ||
      !lua_integer_field(L, idx, "end_offset", &end_offset) ||
      end_offset < start_offset) {
    if (error) *error = treesitter_strdup("Tree-sitter edit has invalid position fields");
    return false;
  }

  lua_getfield(L, idx, "text");
  size_t text_len = 0;
  const char *text = lua_tolstring(L, -1, &text_len);
  if (!text || text_len > UINT32_MAX || start_offset > UINT32_MAX - (uint32_t) text_len) {
    lua_pop(L, 1);
    if (error) *error = treesitter_strdup("Tree-sitter edit has invalid text");
    return false;
  }

  TSPoint new_end_point;
  new_end_point.row = line1 - 1;
  new_end_point.column = col1 - 1;
  for (size_t i = 0; i < text_len; i++) {
    if (text[i] == '\n') {
      new_end_point.row++;
      new_end_point.column = 0;
    } else {
      new_end_point.column++;
    }
  }
  lua_pop(L, 1);

  edit->input_edit.start_byte = start_offset;
  edit->input_edit.old_end_byte = end_offset;
  edit->input_edit.new_end_byte = start_offset + (uint32_t) text_len;
  edit->input_edit.start_point.row = line1 - 1;
  edit->input_edit.start_point.column = col1 - 1;
  edit->input_edit.old_end_point.row = line2 - 1;
  edit->input_edit.old_end_point.column = col2 - 1;
  edit->input_edit.new_end_point = new_end_point;
  return true;
}

static int f_register_complete_event(lua_State *L) {
  if (!anvil_ts_service_register_complete_event()) {
    lua_pushnil(L);
    lua_pushstring(L, "failed to register treesitter_complete event");
    return 2;
  }
  lua_pushboolean(L, true);
  return 1;
}

static int f_ack_complete_event(lua_State *L) {
  (void) L;
  anvil_ts_service_ack_complete_event();
  return 0;
}

static int f_new_document_state(lua_State *L) {
  const char *language_id = luaL_checkstring(L, 1);
  const AnvilTSLanguage *language = anvil_ts_language_by_id(language_id);
  if (!language || !anvil_ts_language_is_compatible(language)) {
    lua_pushnil(L);
    lua_pushfstring(L, "unknown or incompatible Tree-sitter language '%s'", language_id);
    return 2;
  }

  uint32_t parse_timeout_ms = option_uint32(L, 2, "parse_timeout_ms", 750);
  AnvilTSDocumentState *state = anvil_ts_document_state_new(language, parse_timeout_ms);
  if (!state) {
    lua_pushnil(L);
    lua_pushstring(L, "failed to create Tree-sitter document state");
    return 2;
  }

  AnvilTSStateUserdata *userdata = (AnvilTSStateUserdata *) lua_newuserdata(L, sizeof(*userdata));
  userdata->state = state;
  luaL_setmetatable(L, API_TYPE_TREESITTER_STATE);
  return 1;
}

static AnvilTSSnapshot *snapshot_from_lua_lines(lua_State *L, int idx, char **error) {
  if (error) *error = NULL;
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_Unsigned raw_count = (lua_Unsigned) lua_rawlen(L, idx);
  if (raw_count > UINT32_MAX) {
    if (error) *error = treesitter_strdup("too many Tree-sitter snapshot lines");
    return NULL;
  }
  uint32_t line_count = (uint32_t) raw_count;
  const char **lines = line_count ? (const char **) calloc(line_count, sizeof(char *)) : NULL;
  uint32_t *line_lengths = line_count ? (uint32_t *) calloc(line_count, sizeof(uint32_t)) : NULL;
  if (line_count && (!lines || !line_lengths)) {
    free(lines);
    free(line_lengths);
    if (error) *error = treesitter_strdup("out of memory preparing Tree-sitter snapshot lines");
    return NULL;
  }

  for (uint32_t i = 0; i < line_count; i++) {
    lua_rawgeti(L, idx, (int) i + 1);
    size_t len = 0;
    const char *line = lua_tolstring(L, -1, &len);
    if (!line) {
      lua_pop(L, 1);
      free(lines);
      free(line_lengths);
      if (error) *error = treesitter_strdup("Tree-sitter snapshot line is not a string");
      return NULL;
    }
    if (len > UINT32_MAX) {
      lua_pop(L, 1);
      free(lines);
      free(line_lengths);
      if (error) *error = treesitter_strdup("Tree-sitter snapshot line exceeds 4GB byte limit");
      return NULL;
    }
    lines[i] = line;
    line_lengths[i] = (uint32_t) len;
    lua_pop(L, 1);
  }

  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(lines, line_lengths, line_count, error);
  free(lines);
  free(line_lengths);
  return snapshot;
}

static int state_language_id(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  luaL_argcheck(L, userdata->state != NULL, 1, "closed Tree-sitter document state");
  lua_pushstring(L, anvil_ts_document_state_language_id(userdata->state));
  return 1;
}

static int state_status(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  if (!userdata->state) {
    lua_pushstring(L, "closed");
    lua_pushstring(L, "closed");
    return 2;
  }
  AnvilTSStateStatus status = ANVIL_TS_STATE_FAILED;
  char *reason = NULL;
  if (!anvil_ts_document_state_status_snapshot(userdata->state, &status, &reason)) {
    lua_pushstring(L, "failed");
    lua_pushstring(L, "failed to read Tree-sitter document state status");
    return 2;
  }
  lua_pushstring(L, anvil_ts_document_state_status_string(status));
  if (reason) lua_pushstring(L, reason); else lua_pushnil(L);
  free(reason);
  return 2;
}

static int state_generation(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  lua_pushinteger(L, userdata->state ? (lua_Integer) anvil_ts_document_state_generation(userdata->state) : 0);
  return 1;
}

static int state_tree_generation(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  lua_pushinteger(L, userdata->state ? (lua_Integer) anvil_ts_document_state_tree_generation(userdata->state) : 0);
  return 1;
}

static int state_has_tree(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  lua_pushboolean(L, userdata->state && anvil_ts_document_state_has_tree(userdata->state));
  return 1;
}

static int state_schedule_parse(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  luaL_argcheck(L, userdata->state != NULL, 1, "closed Tree-sitter document state");
  luaL_checktype(L, 2, LUA_TTABLE);
  uint64_t generation = (uint64_t) luaL_checkinteger(L, 3);
  AnvilTSEdit edit;
  AnvilTSEdit *edit_ptr = NULL;
  char *error = NULL;
  if (!lua_isnoneornil(L, 4)) {
    if (!edit_from_lua(L, 4, &edit, &error)) {
      lua_pushnil(L);
      lua_pushstring(L, error ? error : "invalid Tree-sitter edit");
      free(error);
      return 2;
    }
    edit_ptr = &edit;
  }

  AnvilTSSnapshot *snapshot = snapshot_from_lua_lines(L, 2, &error);
  if (!snapshot) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "failed to create Tree-sitter snapshot");
    free(error);
    return 2;
  }

  if (!anvil_ts_document_state_schedule_parse_with_edit(userdata->state, snapshot, generation, edit_ptr, &error)) {
    anvil_ts_snapshot_free(snapshot);
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "failed to schedule Tree-sitter parse");
    free(error);
    return 2;
  }
  lua_pushboolean(L, true);
  return 1;
}

static int state_poll(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  luaL_argcheck(L, userdata->state != NULL, 1, "closed Tree-sitter document state");
  uint64_t generation = (uint64_t) luaL_checkinteger(L, 2);
  AnvilTSPollResult result = anvil_ts_document_state_poll(userdata->state, generation);
  lua_pushstring(L, anvil_ts_document_state_status_string(result.status));
  lua_pushboolean(L, result.changed);
  lua_pushboolean(L, result.discarded_stale);
  if (result.changed_ranges_available) {
    lua_createtable(L, (int) result.changed_range_count, 0);
    for (uint32_t i = 0; i < result.changed_range_count; i++) {
      const TSRange *range = &result.changed_ranges[i];
      lua_createtable(L, 0, 6);
      lua_pushinteger(L, (lua_Integer) range->start_byte);
      lua_setfield(L, -2, "start_byte");
      lua_pushinteger(L, (lua_Integer) range->end_byte);
      lua_setfield(L, -2, "end_byte");
      lua_pushinteger(L, (lua_Integer) range->start_point.row + 1);
      lua_setfield(L, -2, "start_line");
      lua_pushinteger(L, (lua_Integer) range->start_point.column + 1);
      lua_setfield(L, -2, "start_col");
      lua_pushinteger(L, (lua_Integer) range->end_point.row + 1);
      lua_setfield(L, -2, "end_line");
      lua_pushinteger(L, (lua_Integer) range->end_point.column + 1);
      lua_setfield(L, -2, "end_col");
      lua_rawseti(L, -2, (lua_Integer) i + 1);
    }
  } else {
    lua_pushnil(L);
  }
  free(result.changed_ranges);
  return 4;
}

typedef struct LuaCaptureCopy {
  char *name;
  uint32_t name_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  int32_t priority;
  uint32_t match_id;
  uint32_t pattern_index;
  uint32_t capture_index;
  uint32_t order;
} LuaCaptureCopy;

typedef struct LuaCaptureCollectContext {
  LuaCaptureCopy *items;
  uint32_t count;
  uint32_t capacity;
  bool failed;
} LuaCaptureCollectContext;

static void free_capture_copies(LuaCaptureCollectContext *context) {
  if (!context) return;
  for (uint32_t i = 0; i < context->count; i++) free(context->items[i].name);
  free(context->items);
  context->items = NULL;
  context->count = 0;
  context->capacity = 0;
}

static bool collect_query_capture(const AnvilTSQueryCapture *capture, void *payload) {
  LuaCaptureCollectContext *context = (LuaCaptureCollectContext *) payload;
  if (context->count == context->capacity) {
    uint32_t next_capacity = context->capacity ? context->capacity * 2 : 64;
    LuaCaptureCopy *next = (LuaCaptureCopy *) realloc(context->items, sizeof(*next) * next_capacity);
    if (!next) {
      context->failed = true;
      return false;
    }
    context->items = next;
    context->capacity = next_capacity;
  }
  LuaCaptureCopy *copy = &context->items[context->count];
  memset(copy, 0, sizeof(*copy));
  copy->name = (char *) malloc((size_t) capture->name_len + 1);
  if (!copy->name) {
    context->failed = true;
    return false;
  }
  memcpy(copy->name, capture->name, capture->name_len);
  copy->name[capture->name_len] = '\0';
  copy->name_len = capture->name_len;
  copy->start_byte = capture->start_byte;
  copy->end_byte = capture->end_byte;
  copy->start_point = capture->start_point;
  copy->end_point = capture->end_point;
  copy->priority = capture->priority;
  copy->match_id = capture->match_id;
  copy->pattern_index = capture->pattern_index;
  copy->capture_index = capture->capture_index;
  copy->order = capture->order;
  context->count++;
  return true;
}

static void push_capture_copy(lua_State *L, const LuaCaptureCopy *capture) {
  lua_newtable(L);
  lua_pushlstring(L, capture->name, capture->name_len);
  lua_setfield(L, -2, "capture");
  lua_pushinteger(L, (lua_Integer) capture->start_byte);
  lua_setfield(L, -2, "start_byte");
  lua_pushinteger(L, (lua_Integer) capture->end_byte);
  lua_setfield(L, -2, "end_byte");
  lua_pushinteger(L, (lua_Integer) capture->start_point.row + 1);
  lua_setfield(L, -2, "start_line");
  lua_pushinteger(L, (lua_Integer) capture->start_point.column + 1);
  lua_setfield(L, -2, "start_col");
  lua_pushinteger(L, (lua_Integer) capture->end_point.row + 1);
  lua_setfield(L, -2, "end_line");
  lua_pushinteger(L, (lua_Integer) capture->end_point.column + 1);
  lua_setfield(L, -2, "end_col");
  lua_pushinteger(L, (lua_Integer) capture->priority);
  lua_setfield(L, -2, "priority");
  lua_pushinteger(L, (lua_Integer) capture->match_id);
  lua_setfield(L, -2, "match_id");
  lua_pushinteger(L, (lua_Integer) capture->pattern_index);
  lua_setfield(L, -2, "pattern_index");
  lua_pushinteger(L, (lua_Integer) capture->capture_index);
  lua_setfield(L, -2, "capture_index");
  lua_pushinteger(L, (lua_Integer) capture->order);
  lua_setfield(L, -2, "order");
}

typedef struct LuaSyncParseRun {
  uint64_t started_ticks;
  uint32_t timeout_ms;
  AnvilWorkerCancelToken *cancel_token;
  bool timed_out;
  bool cancelled;
} LuaSyncParseRun;

static bool worker_cancel_token_cancelled_callback(void *payload) {
  return anvil_worker_cancel_token_cancelled((AnvilWorkerCancelToken *) payload);
}

static bool sync_parse_progress(TSParseState *parse_state) {
  LuaSyncParseRun *run = (LuaSyncParseRun *) parse_state->payload;
  if (!run) return false;
  if (anvil_worker_cancel_token_cancelled(run->cancel_token)) {
    run->cancelled = true;
    return true;
  }
  if (run->timeout_ms > 0) {
    uint64_t elapsed = SDL_GetTicks() - run->started_ticks;
    if (elapsed >= run->timeout_ms) {
      run->timed_out = true;
      return true;
    }
  }
  return false;
}

static TSQuery *compile_query_source(
  lua_State *L,
  const AnvilTSLanguage *language,
  const char *kind,
  const char *source,
  size_t source_len
) {
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *query = ts_query_new(
    anvil_ts_language_ptr(language),
    source,
    (uint32_t) source_len,
    &error_offset,
    &error_type
  );
  if (!query) {
    lua_pushnil(L);
    lua_pushfstring(
      L,
      "Tree-sitter %s query error %d at byte %d",
      kind,
      (int) error_type,
      (int) error_offset
    );
    return NULL;
  }
  return query;
}

static void set_metric_number(lua_State *L, int metrics_index, const char *field, lua_Number value) {
  lua_pushnumber(L, value);
  lua_setfield(L, metrics_index, field);
}

static const char *query_status_from_error(const char *error, bool exceeded_match_limit) {
  if (exceeded_match_limit) return "limit";
  if (!error) return "failed";
  if (strstr(error, "cancelled")) return "cancelled";
  if (strstr(error, "timed out")) return "timeout";
  if (strstr(error, "limit exceeded")) return "limit";
  return "failed";
}

static void push_query_result_table(
  lua_State *L,
  int result_index,
  const char *field,
  const LuaCaptureCollectContext *context,
  bool exceeded_match_limit,
  const char *status,
  const char *error
) {
  uint32_t count = context ? context->count : 0;
  lua_newtable(L);
  lua_newtable(L);
  for (uint32_t i = 0; context && i < context->count; i++) {
    push_capture_copy(L, &context->items[i]);
    lua_rawseti(L, -2, (int) i + 1);
  }
  lua_setfield(L, -2, "captures");
  lua_pushboolean(L, exceeded_match_limit);
  lua_setfield(L, -2, "exceeded_match_limit");
  lua_pushinteger(L, (lua_Integer) count);
  lua_setfield(L, -2, "capture_count");
  lua_pushstring(L, status ? status : "ready");
  lua_setfield(L, -2, "status");
  if (error && error[0]) {
    lua_pushstring(L, error);
    lua_setfield(L, -2, "error");
  }
  lua_setfield(L, result_index, field);
}

static bool index_text_query(
  lua_State *L,
  int result_index,
  int metrics_index,
  const char *field,
  const AnvilTSLanguage *language,
  const char *source,
  size_t source_len,
  TSTree *tree,
  const AnvilTSSnapshot *snapshot,
  uint32_t match_limit,
  uint32_t max_captures,
  uint32_t timeout_ms,
  AnvilWorkerCancelToken *cancel_token
) {
  if (!source) return true;
  uint64_t query_started_ticks = SDL_GetTicks();
  TSQuery *query = compile_query_source(L, language, field, source, source_len);
  if (!query) {
    const char *compile_error = lua_tostring(L, -1);
    char error_copy[256];
    snprintf(error_copy, sizeof(error_copy), "%s", compile_error ? compile_error : "Tree-sitter query compile failed");
    lua_pop(L, 2);
    push_query_result_table(L, result_index, field, NULL, false, "failed", error_copy);
    if (metrics_index > 0) {
      char metric_field[64];
      snprintf(metric_field, sizeof(metric_field), "%s_query_ms", field);
      set_metric_number(L, metrics_index, metric_field, (lua_Number) (SDL_GetTicks() - query_started_ticks));
    }
    return true;
  }

  LuaCaptureCollectContext context;
  memset(&context, 0, sizeof(context));
  bool exceeded_match_limit = false;
  char *error = NULL;
  bool ok = anvil_ts_query_captures_in_tree(
    tree,
    snapshot,
    query,
    0,
    snapshot->byte_len,
    match_limit,
    max_captures,
    timeout_ms,
    collect_query_capture,
    &context,
    cancel_token ? worker_cancel_token_cancelled_callback : NULL,
    cancel_token,
    &exceeded_match_limit,
    &error
  );
  ts_query_delete(query);
  uint64_t query_elapsed_ms = SDL_GetTicks() - query_started_ticks;

  const char *status = ok ? (exceeded_match_limit ? "limit" : "ready") : query_status_from_error(error, exceeded_match_limit);
  const char *message = error ? error : (context.failed ? "out of memory collecting Tree-sitter captures" : NULL);
  push_query_result_table(L, result_index, field, &context, exceeded_match_limit, status, message);
  if (metrics_index > 0) {
    char metric_field[64];
    snprintf(metric_field, sizeof(metric_field), "%s_query_ms", field);
    set_metric_number(L, metrics_index, metric_field, (lua_Number) query_elapsed_ms);
  }
  free(error);
  free_capture_copies(&context);
  return true;
}

static int f_index_text(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int opts = 1;

  lua_getfield(L, opts, "language");
  const char *language_id = luaL_checkstring(L, -1);
  lua_pop(L, 1);
  const AnvilTSLanguage *language = anvil_ts_language_by_id(language_id);
  if (!language || !anvil_ts_language_is_compatible(language)) {
    lua_pushnil(L);
    lua_pushfstring(L, "unknown or incompatible Tree-sitter language '%s'", language_id);
    return 2;
  }

  lua_getfield(L, opts, "lines");
  if (!lua_istable(L, -1)) {
    lua_pushnil(L);
    lua_pushstring(L, "Tree-sitter index_text requires a lines table");
    return 2;
  }
  char *error = NULL;
  AnvilTSSnapshot *snapshot = snapshot_from_lua_lines(L, -1, &error);
  lua_pop(L, 1);
  if (!snapshot) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : "failed to create Tree-sitter snapshot");
    free(error);
    return 2;
  }

  uint32_t parse_timeout_ms = option_uint32(L, opts, "parse_timeout_ms", 750);
  uint32_t query_timeout_ms = option_uint32(L, opts, "query_timeout_ms", 20);
  uint32_t match_limit = option_uint32(L, opts, "match_limit", 50000);
  uint32_t max_captures = option_uint32(L, opts, "max_captures", 50000);
  uint32_t usage_query_timeout_ms = option_uint32(L, opts, "usage_query_timeout_ms", query_timeout_ms);
  uint32_t usage_match_limit = option_uint32(L, opts, "usage_match_limit", match_limit);
  uint32_t usage_max_captures = option_uint32(L, opts, "usage_max_captures", max_captures);
  lua_getfield(L, opts, "cancel_token");
  const char *cancel_token_name = lua_tostring(L, -1);
  AnvilWorkerCancelToken *cancel_token = cancel_token_name ? anvil_worker_cancel_token_open(cancel_token_name) : NULL;
  lua_pop(L, 1);

  TSParser *parser = ts_parser_new();
  if (!parser) {
    anvil_ts_snapshot_free(snapshot);
    anvil_worker_cancel_token_release(cancel_token);
    lua_pushnil(L);
    lua_pushstring(L, "failed to allocate Tree-sitter parser");
    return 2;
  }
  if (!ts_parser_set_language(parser, anvil_ts_language_ptr(language))) {
    ts_parser_delete(parser);
    anvil_ts_snapshot_free(snapshot);
    anvil_worker_cancel_token_release(cancel_token);
    lua_pushnil(L);
    lua_pushstring(L, "failed to set Tree-sitter parser language");
    return 2;
  }

  LuaSyncParseRun run;
  memset(&run, 0, sizeof(run));
  run.started_ticks = SDL_GetTicks();
  run.timeout_ms = parse_timeout_ms;
  run.cancel_token = cancel_token;
  TSParseOptions parse_options;
  parse_options.payload = &run;
  parse_options.progress_callback = sync_parse_progress;
  TSInput input = anvil_ts_snapshot_input(snapshot);
  TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, parse_options);
  uint64_t parse_elapsed_ms = SDL_GetTicks() - run.started_ticks;
  ts_parser_delete(parser);
  if (!tree) {
    anvil_ts_snapshot_free(snapshot);
    lua_pushnil(L);
    lua_pushstring(L, run.cancelled ? "Tree-sitter parse cancelled" : (run.timed_out ? "Tree-sitter parse timed out" : "Tree-sitter parse failed"));
    anvil_worker_cancel_token_release(cancel_token);
    return 2;
  }

  lua_newtable(L);
  int result_index = lua_gettop(L);
  lua_pushstring(L, language->id);
  lua_setfield(L, result_index, "language");
  lua_pushinteger(L, (lua_Integer) snapshot->byte_len);
  lua_setfield(L, result_index, "byte_len");

  lua_newtable(L);
  int metrics_index = lua_gettop(L);
  set_metric_number(L, metrics_index, "parse_ms", (lua_Number) parse_elapsed_ms);
  lua_pushinteger(L, 1);
  lua_setfield(L, metrics_index, "parse_count");

  size_t outline_len = 0;
  lua_getfield(L, opts, "outline_query");
  const char *outline_source = lua_tolstring(L, -1, &outline_len);
  if (outline_source && !index_text_query(L, result_index, metrics_index, "outline", language, outline_source, outline_len, tree, snapshot, match_limit, max_captures, query_timeout_ms, cancel_token)) {
    ts_tree_delete(tree);
    anvil_ts_snapshot_free(snapshot);
    anvil_worker_cancel_token_release(cancel_token);
    return 2;
  }
  lua_pop(L, 1);

  size_t usage_len = 0;
  lua_getfield(L, opts, "usage_query");
  const char *usage_source = lua_tolstring(L, -1, &usage_len);
  if (usage_source && !index_text_query(L, result_index, metrics_index, "usage", language, usage_source, usage_len, tree, snapshot, usage_match_limit, usage_max_captures, usage_query_timeout_ms, cancel_token)) {
    ts_tree_delete(tree);
    anvil_ts_snapshot_free(snapshot);
    anvil_worker_cancel_token_release(cancel_token);
    return 2;
  }
  lua_pop(L, 1);

  lua_setfield(L, result_index, "metrics");
  ts_tree_delete(tree);
  anvil_ts_snapshot_free(snapshot);
  anvil_worker_cancel_token_release(cancel_token);
  return 1;
}

typedef struct LuaNodeRangeCopy {
  char *type;
  uint32_t type_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  bool named;
} LuaNodeRangeCopy;

typedef struct LuaNodeRangeCollectContext {
  LuaNodeRangeCopy *items;
  uint32_t count;
  uint32_t capacity;
  bool failed;
} LuaNodeRangeCollectContext;

static void free_node_range_copies(LuaNodeRangeCollectContext *context) {
  if (!context) return;
  for (uint32_t i = 0; i < context->count; i++) free(context->items[i].type);
  free(context->items);
  context->items = NULL;
  context->count = 0;
  context->capacity = 0;
}

static bool collect_node_range(const AnvilTSNodeRange *range, void *payload) {
  LuaNodeRangeCollectContext *context = (LuaNodeRangeCollectContext *) payload;
  if (context->count == context->capacity) {
    uint32_t next_capacity = context->capacity ? context->capacity * 2 : 32;
    LuaNodeRangeCopy *next = (LuaNodeRangeCopy *) realloc(context->items, sizeof(*next) * next_capacity);
    if (!next) {
      context->failed = true;
      return false;
    }
    context->items = next;
    context->capacity = next_capacity;
  }
  LuaNodeRangeCopy *copy = &context->items[context->count];
  memset(copy, 0, sizeof(*copy));
  copy->type = (char *) malloc((size_t) range->type_len + 1);
  if (!copy->type) {
    context->failed = true;
    return false;
  }
  memcpy(copy->type, range->type, range->type_len);
  copy->type[range->type_len] = '\0';
  copy->type_len = range->type_len;
  copy->start_byte = range->start_byte;
  copy->end_byte = range->end_byte;
  copy->start_point = range->start_point;
  copy->end_point = range->end_point;
  copy->named = range->named;
  context->count++;
  return true;
}

static void push_node_range_copy(lua_State *L, const LuaNodeRangeCopy *range) {
  lua_newtable(L);
  lua_pushlstring(L, range->type, range->type_len);
  lua_setfield(L, -2, "type");
  lua_pushboolean(L, range->named);
  lua_setfield(L, -2, "named");
  lua_pushinteger(L, (lua_Integer) range->start_byte);
  lua_setfield(L, -2, "start_byte");
  lua_pushinteger(L, (lua_Integer) range->end_byte);
  lua_setfield(L, -2, "end_byte");
  lua_pushinteger(L, (lua_Integer) range->start_point.row + 1);
  lua_setfield(L, -2, "start_line");
  lua_pushinteger(L, (lua_Integer) range->start_point.column + 1);
  lua_setfield(L, -2, "start_col");
  lua_pushinteger(L, (lua_Integer) range->end_point.row + 1);
  lua_setfield(L, -2, "end_line");
  lua_pushinteger(L, (lua_Integer) range->end_point.column + 1);
  lua_setfield(L, -2, "end_col");
}

static int state_node_ranges(lua_State *L) {
  AnvilTSStateUserdata *state_userdata = check_state(L, 1);
  luaL_argcheck(L, state_userdata->state != NULL, 1, "closed Tree-sitter document state");
  uint32_t byte_start = (uint32_t) luaL_checkinteger(L, 2);
  uint32_t byte_end = (uint32_t) luaL_checkinteger(L, 3);
  bool named_only = true;
  uint32_t max_nodes = 128;
  if (lua_istable(L, 4)) {
    lua_getfield(L, 4, "named_only");
    if (lua_isboolean(L, -1)) named_only = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    max_nodes = option_uint32(L, 4, "max_nodes", max_nodes);
  }

  LuaNodeRangeCollectContext context;
  memset(&context, 0, sizeof(context));
  char *error = NULL;
  bool ok = anvil_ts_document_state_node_ranges(
    state_userdata->state,
    byte_start,
    byte_end,
    named_only,
    max_nodes,
    collect_node_range,
    &context,
    &error
  );
  if (!ok) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : (context.failed ? "out of memory collecting Tree-sitter node ranges" : "Tree-sitter node range query failed"));
    free(error);
    free_node_range_copies(&context);
    return 2;
  }

  lua_newtable(L);
  for (uint32_t i = 0; i < context.count; i++) {
    push_node_range_copy(L, &context.items[i]);
    lua_rawseti(L, -2, (int) i + 1);
  }
  free_node_range_copies(&context);
  return 1;
}

static int state_query_captures(lua_State *L) {
  AnvilTSStateUserdata *state_userdata = check_state(L, 1);
  AnvilTSQueryUserdata *query_userdata = check_query(L, 2);
  luaL_argcheck(L, state_userdata->state != NULL, 1, "closed Tree-sitter document state");
  luaL_argcheck(L, query_userdata->query != NULL, 2, "closed Tree-sitter query");
  uint32_t byte_start = (uint32_t) luaL_checkinteger(L, 3);
  uint32_t byte_end = (uint32_t) luaL_checkinteger(L, 4);
  uint32_t match_limit = option_uint32(L, 5, "match_limit", 50000);
  uint32_t max_captures = option_uint32(L, 5, "max_captures", 50000);
  uint32_t timeout_ms = option_uint32(L, 5, "timeout_ms", 8);

  LuaCaptureCollectContext context;
  memset(&context, 0, sizeof(context));
  bool exceeded_match_limit = false;
  char *error = NULL;
  bool ok = anvil_ts_document_state_query_captures(
    state_userdata->state,
    query_userdata->query,
    byte_start,
    byte_end,
    match_limit,
    max_captures,
    timeout_ms,
    collect_query_capture,
    &context,
    &exceeded_match_limit,
    &error
  );
  if (!ok) {
    lua_pushnil(L);
    lua_pushstring(L, error ? error : (context.failed ? "out of memory collecting Tree-sitter captures" : "Tree-sitter query failed"));
    free(error);
    free_capture_copies(&context);
    return 2;
  }

  lua_newtable(L);
  for (uint32_t i = 0; i < context.count; i++) {
    push_capture_copy(L, &context.items[i]);
    lua_rawseti(L, -2, (int) i + 1);
  }
  free_capture_copies(&context);
  lua_pushboolean(L, exceeded_match_limit);
  lua_setfield(L, -2, "exceeded_match_limit");
  return 1;
}

static int state_cancel(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  if (userdata->state) anvil_ts_document_state_cancel(userdata->state);
  return 0;
}

static int state_close(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  if (userdata->state) anvil_ts_document_state_close(userdata->state);
  return 0;
}

static int state_gc(lua_State *L) {
  AnvilTSStateUserdata *userdata = check_state(L, 1);
  if (userdata->state) {
    anvil_ts_document_state_close(userdata->state);
    anvil_ts_document_state_release(userdata->state);
    userdata->state = NULL;
  }
  return 0;
}

static int query_gc(lua_State *L) {
  AnvilTSQueryUserdata *userdata = check_query(L, 1);
  if (userdata->query) {
    ts_query_delete(userdata->query);
    userdata->query = NULL;
  }
  userdata->language = NULL;
  return 0;
}

static int query_capture_names(lua_State *L) {
  AnvilTSQueryUserdata *userdata = check_query(L, 1);
  luaL_argcheck(L, userdata->query != NULL, 1, "closed Tree-sitter query");

  lua_newtable(L);
  uint32_t count = ts_query_capture_count(userdata->query);
  for (uint32_t i = 0; i < count; i++) {
    uint32_t len = 0;
    const char *name = ts_query_capture_name_for_id(userdata->query, i, &len);
    lua_pushlstring(L, name, len);
    lua_rawseti(L, -2, (int) i + 1);
  }
  return 1;
}

static int query_pattern_count(lua_State *L) {
  AnvilTSQueryUserdata *userdata = check_query(L, 1);
  luaL_argcheck(L, userdata->query != NULL, 1, "closed Tree-sitter query");
  lua_pushinteger(L, ts_query_pattern_count(userdata->query));
  return 1;
}

static int query_language_id(lua_State *L) {
  AnvilTSQueryUserdata *userdata = check_query(L, 1);
  lua_pushstring(L, userdata->language ? userdata->language->id : NULL);
  return 1;
}

static const luaL_Reg query_methods[] = {
  { "capture_names", query_capture_names },
  { "pattern_count", query_pattern_count },
  { "language_id", query_language_id },
  { NULL, NULL }
};

static const luaL_Reg query_meta[] = {
  { "__gc", query_gc },
  { NULL, NULL }
};

static const luaL_Reg state_methods[] = {
  { "language_id", state_language_id },
  { "status", state_status },
  { "generation", state_generation },
  { "tree_generation", state_tree_generation },
  { "has_tree", state_has_tree },
  { "schedule_parse", state_schedule_parse },
  { "poll", state_poll },
  { "query_captures", state_query_captures },
  { "node_ranges", state_node_ranges },
  { "cancel", state_cancel },
  { "close", state_close },
  { NULL, NULL }
};

static const luaL_Reg state_meta[] = {
  { "__gc", state_gc },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "runtime_version", f_runtime_version },
  { "runtime_abi_version", f_runtime_abi_version },
  { "language_ids", f_language_ids },
  { "has_language", f_has_language },
  { "language_version", f_language_version },
  { "compile_query", f_compile_query },
  { "index_text", f_index_text },
  { "register_complete_event", f_register_complete_event },
  { "ack_complete_event", f_ack_complete_event },
  { "new_document_state", f_new_document_state },
  { NULL, NULL }
};

int luaopen_treesitter(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_TREESITTER_QUERY);
  luaL_setfuncs(L, query_meta, 0);
  lua_newtable(L);
  luaL_setfuncs(L, query_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_TREESITTER_STATE);
  luaL_setfuncs(L, state_meta, 0);
  lua_newtable(L);
  luaL_setfuncs(L, state_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
