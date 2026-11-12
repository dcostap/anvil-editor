#include "api.h"
#include "../sql_batch.h"
#include "../sql_context.h"
#include "../sql_server.h"
#include "../sql_query.h"
#include "../sql_definition.h"
#include "../sql_format.h"
#include "../worker_pool.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static void text(lua_State *L, const char *key, const char *value) {
  lua_pushstring(L, value ? value : ""); lua_setfield(L, -2, key);
}
static void boolean(lua_State *L, const char *key, int value) {
  lua_pushboolean(L, value); lua_setfield(L, -2, key);
}
static int context(lua_State *L) {
  size_t length;
  const char *s = luaL_checklstring(L, 1, &length);
  lua_Integer caret = luaL_checkinteger(L, 2);
  luaL_argcheck(L, caret >= 0 && (size_t)caret <= length, 2, "invalid byte offset");
  SqlContext out;
  if (!sql_context_parse(s, length, (size_t)caret, &out)) {
    lua_pushnil(L); lua_pushliteral(L, "SQL context exceeds the supported size."); return 2;
  }
  lua_newtable(L);
  text(L, "mode", out.mode == SQL_CONTEXT_TABLE ? "table" : out.mode == SQL_CONTEXT_COLUMN ? "column" : out.mode == SQL_CONTEXT_OBJECT ? "object" : "none");
  boolean(L,"star",out.star);
  text(L,"object_kind",out.object_kind);
  text(L, "prefix", out.prefix); text(L, "qualifier", out.qualifier);
  lua_pushinteger(L, (lua_Integer)out.start); lua_setfield(L, -2, "start");
  lua_pushinteger(L, (lua_Integer)out.end); lua_setfield(L, -2, "end");
  lua_createtable(L, (int)out.count, 0);
  for (size_t i = 0; i < out.count; ++i) {
    lua_newtable(L);
    text(L, "schema", out.sources[i].schema); text(L, "name", out.sources[i].name); text(L, "alias", out.sources[i].alias);
    if (out.sources[i].local) { lua_pushinteger(L, (lua_Integer)out.sources[i].local); lua_setfield(L, -2, "local_index"); }
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "sources");
  static const char *kinds[] = { "", "cte", "derived", "temp", "variable" };
  lua_createtable(L, (int)out.local_count, 0);
  for (size_t i = 0; i < out.local_count; ++i) {
    SqlLocal *local = &out.locals[i];
    lua_newtable(L);
    text(L, "name", local->name); text(L, "kind", kinds[local->kind]); boolean(L, "star", local->star);
    lua_createtable(L, (int)local->count, 0);
    for (size_t c = 0; c < local->count; ++c) {
      lua_pushstring(L, out.columns[local->first + c]); lua_rawseti(L, -2, (int)c + 1);
    }
    lua_setfield(L, -2, "columns");
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "locals");
  sql_context_free(&out);
  return 1;
}
static const char *option(lua_State *L, const char *key) {
  lua_getfield(L, 1, key);
  size_t len;
  const char *s = luaL_optlstring(L, -1, "", &len);
  luaL_argcheck(L, len <= 1024 && strlen(s) == len, 1, "invalid connection setting");
  /* Keep the value rooted until the blocking call returns. */
  return s;
}
static int catalog_gc(lua_State *L) {
  sql_server_catalog_free(luaL_checkudata(L, 1, "anvil.sql_catalog")); return 0;
}
static SqlServerOptions read_options(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  SqlServerOptions options = {0};
  options.server = option(L, "server"); options.database = option(L, "database");
  options.user = option(L, "user"); options.password = option(L, "password");
  lua_getfield(L, 1, "integrated"); options.integrated = lua_toboolean(L, -1);
  lua_getfield(L, 1, "trust_certificate"); options.trust_certificate = lua_toboolean(L, -1);
  lua_getfield(L, 1, "encrypt"); options.encrypt = lua_isnil(L, -1) || lua_toboolean(L, -1);
  return options;
}
static void push_column(lua_State *L, const SqlServerColumn *column) {
  lua_newtable(L);
  text(L, "name", column->name); text(L, "type", column->type);
  boolean(L, "nullable", column->nullable); boolean(L, "identity", column->identity);
  boolean(L, "primary_key", column->primary_key);
}
static int read_schema(lua_State *L) {
  SqlServerOptions options = read_options(L);
  SqlServerCatalog *c = lua_newuserdata(L, sizeof(*c));
  memset(c, 0, sizeof(*c));
  luaL_setmetatable(L, "anvil.sql_catalog");
  if (!sql_server_read_schema(&options, c)) {
    lua_pushnil(L); lua_pushstring(L, c->error);
    sql_server_catalog_free(c); return 2;
  }
  lua_newtable(L);
  text(L, "database", c->database); text(L, "default_schema", c->default_schema);
  boolean(L, "case_sensitive", c->case_sensitive);
  boolean(L, "columns_loaded", c->columns_loaded);
  boolean(L, "objects_truncated", c->objects_truncated);
  if (c->metadata_error[0]) text(L, "metadata_error", c->metadata_error);
  lua_newtable(L);
  size_t column_index = 0;
  for (size_t i = 0; i < c->object_count; ++i) {
    SqlServerObject *object=&c->objects[i];
    lua_newtable(L);
    text(L,"schema",object->schema); text(L,"name",object->name); text(L,"kind",object->kind);
    /* A table or view without loaded columns has no columns field. */
    int has_columns = c->columns_loaded || (strcmp(object->kind, "table") && strcmp(object->kind, "view"));
    if (has_columns) {
      lua_newtable(L);
      size_t index=0;
      while (column_index<c->count) {
        SqlServerColumn *column=&c->columns[column_index];
        if (strcmp(object->schema,column->schema) || strcmp(object->name,column->table)) break;
        push_column(L, column);
        lua_rawseti(L,-2,++index); ++column_index;
      }
      lua_setfield(L,-2,"columns");
    }
    lua_rawseti(L,-2,i+1);
  }
  lua_setfield(L, -2, "objects");
  sql_server_catalog_free(c);
  return 1;
}
static int read_columns(lua_State *L) {
  size_t slen, nlen;
  const char *schema = luaL_checklstring(L, 2, &slen), *name = luaL_checklstring(L, 3, &nlen);
  luaL_argcheck(L, slen > 0 && slen <= 512 && strlen(schema) == slen, 2, "invalid object schema");
  luaL_argcheck(L, nlen > 0 && nlen <= 512 && strlen(name) == nlen, 3, "invalid object name");
  SqlServerOptions options = read_options(L);
  SqlServerCatalog *c = lua_newuserdata(L, sizeof(*c));
  memset(c, 0, sizeof(*c));
  luaL_setmetatable(L, "anvil.sql_catalog");
  if (!sql_server_read_columns(&options, schema, name, c)) {
    lua_pushnil(L); lua_pushstring(L, c->error);
    sql_server_catalog_free(c); return 2;
  }
  lua_createtable(L, (int)c->count, 0);
  for (size_t i = 0; i < c->count; ++i) { push_column(L, &c->columns[i]); lua_rawseti(L, -2, (int)i + 1); }
  sql_server_catalog_free(c);
  return 1;
}
static int query_gc(lua_State *L) {
  sql_query_free(luaL_checkudata(L, 1, "anvil.sql_query")); return 0;
}
static bool query_cancelled(void *token) {
  return anvil_worker_cancel_token_cancelled(token);
}
static lua_Integer setting(lua_State *L, const char *key, lua_Integer fallback) {
  lua_getfield(L, 3, key);
  lua_Integer value = luaL_optinteger(L, -1, fallback);
  lua_pop(L, 1);
  return value;
}
static int flag(lua_State *L, const char *key, int fallback) {
  lua_getfield(L, 3, key);
  int value = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1);
  lua_pop(L, 1);
  return value;
}
static void push_result(lua_State *L, SqlQueryResult *result) {
  lua_newtable(L);
  if (result->error[0]) text(L, "error", result->error);
  if (result->error_line) { lua_pushinteger(L, result->error_line); lua_setfield(L, -2, "error_line"); }
  boolean(L, "cancelled", result->cancelled);
  boolean(L, "limited", result->limited);
  boolean(L, "session_lost", result->session_lost);
  if (result->transaction_count >= 0) {
    lua_pushinteger(L, result->transaction_count); lua_setfield(L, -2, "transaction_count");
  }
  if (result->database[0]) text(L, "database", result->database);
  lua_newtable(L);
  int tables = 0;
  for (size_t i = 0; i < result->count; ++i) {
    SqlQueryTable *t = &result->tables[i];
    if (!t->column_count || !t->columns) continue;
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)t->column_count); lua_setfield(L, -2, "column_count");
    text(L, "missing_label", "NULL");
    if (t->truncated) text(L, "warning", "Row or cell limit reached. This result is incomplete.");
    boolean(L, "truncated", t->truncated);
    lua_newtable(L);
    for (size_t col = 0; col < t->column_count; ++col) {
      lua_pushstring(L, t->columns[col] ? t->columns[col] : ""); lua_rawseti(L, -2, (int)col + 1);
    }
    lua_setfield(L, -2, "headers");
    lua_newtable(L);
    for (size_t col = 0; col < t->column_count; ++col) {
      lua_pushstring(L, t->numeric && t->numeric[col] ? "number" : "text"); lua_rawseti(L, -2, (int)col + 1);
    }
    lua_setfield(L, -2, "column_kinds");
    lua_createtable(L, (int)t->row_count, 0);
    for (size_t row = 0; row < t->row_count; ++row) {
      lua_createtable(L, 0, 3);
      lua_pushinteger(L, (lua_Integer)row + 1); lua_setfield(L, -2, "source_line1");
      lua_pushinteger(L, (lua_Integer)row + 1); lua_setfield(L, -2, "source_line2");
      lua_createtable(L, (int)t->column_count, 0);
      for (size_t col = 0; col < t->column_count; ++col) {
        SqlQueryCell *cell = &t->cells[row * t->column_count + col];
        if (cell->text) lua_pushlstring(L, cell->text, cell->length); else lua_pushboolean(L, 0);
        lua_rawseti(L, -2, (int)col + 1);
      }
      lua_setfield(L, -2, "cells");
      lua_rawseti(L, -2, (int)row + 1);
    }
    lua_setfield(L, -2, "rows");
    lua_rawseti(L, -2, ++tables);
  }
  lua_setfield(L, -2, "results");
  lua_createtable(L, (int)result->message_count, 0);
  for (size_t i = 0; i < result->message_count; ++i) {
    lua_createtable(L, 0, 3);
    text(L, "text", result->messages[i].text);
    if (result->messages[i].line) { lua_pushinteger(L, result->messages[i].line); lua_setfield(L, -2, "line"); }
    boolean(L, "error", result->messages[i].error);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "messages");
}
/* execute(options, text, settings). Settings: session, autocommit, explain,
 * max_rows, timeout and token. Without a session, a valid run opens one and
 * the result names it. Invalid text fails before any connection opens. */
static int execute_query(lua_State *L) {
  size_t length;
  const char *sql = luaL_checklstring(L, 2, &length);
  luaL_checktype(L, 3, LUA_TTABLE);
  lua_Integer session = setting(L, "session", 0);
  lua_Integer max_rows = setting(L, "max_rows", 1000), timeout = setting(L, "timeout", 0);
  luaL_argcheck(L, session >= 0 && session <= 0xffffffffLL, 3, "invalid session");
  luaL_argcheck(L, max_rows > 0 && max_rows <= SQL_QUERY_ROW_LIMIT, 3, "invalid row limit");
  luaL_argcheck(L, timeout >= 0 && timeout <= SQL_QUERY_TIMEOUT_MAX, 3, "invalid timeout");
  int autocommit = flag(L, "autocommit", 1), explain = flag(L, "explain", 0);
  lua_getfield(L, 3, "token");
  const char *token_name = luaL_optstring(L, -1, NULL);
  SqlServerOptions options = read_options(L);
  SqlQueryResult *result = lua_newuserdata(L, sizeof(*result));
  memset(result, 0, sizeof(*result));
  luaL_setmetatable(L, "anvil.sql_query");
  result->transaction_count = -1;
  if (!sql_query_check(sql, length, (unsigned)max_rows, (unsigned)timeout, result->error, sizeof(result->error))) {
    push_result(L, result); return 1;
  }
  int opened = 0;
  if (!session) {
    session = sql_session_open(&options, result->error);
    if (!session) { push_result(L, result); return 1; }
    opened = 1;
  }
  AnvilWorkerCancelToken *token = token_name ? anvil_worker_cancel_token_open(token_name) : NULL;
  if (token_name && !token) {
    if (opened) sql_session_close((unsigned)session);
    return luaL_argerror(L, 3, "cancel token unavailable");
  }
  sql_session_execute((unsigned)session, autocommit, explain, sql, length, (unsigned)max_rows, (unsigned)timeout,
                      token ? query_cancelled : NULL, token, result);
  if (token) anvil_worker_cancel_token_release(token);
  push_result(L, result);
  if (!result->session_lost) { lua_pushinteger(L, session); lua_setfield(L, -2, "session"); }
  /* Explain runs nothing, so it changes no catalog. */
  boolean(L, "schema_changed", !explain && sql_batch_changes_schema(sql, length));
  sql_query_free(result);
  return 1;
}
static lua_Integer check_session(lua_State *L) {
  lua_Integer session = luaL_checkinteger(L, 1);
  luaL_argcheck(L, session > 0 && session <= 0xffffffffLL, 1, "invalid session");
  return session;
}
static int end_transaction(lua_State *L) {
  lua_Integer session = check_session(L);
  int count = -1, ended = 0;
  char error[256];
  if (!sql_session_end_transaction((unsigned)session, lua_toboolean(L, 2), &count, &ended, error)) {
    lua_pushnil(L); lua_pushstring(L, error); lua_pushboolean(L, ended); return 3;
  }
  lua_pushinteger(L, count); return 1;
}
static int close_session(lua_State *L) {
  sql_session_close((unsigned)check_session(L)); return 0;
}
static int definition_gc(lua_State *L) {
  sql_definition_free(luaL_checkudata(L, 1, "anvil.sql_definition")); return 0;
}
static int read_definition(lua_State *L) {
  size_t slen, nlen;
  const char *schema = luaL_checklstring(L, 2, &slen), *name = luaL_checklstring(L, 3, &nlen);
  luaL_argcheck(L, slen > 0 && slen <= 512 && strlen(schema) == slen, 2, "invalid object schema");
  luaL_argcheck(L, nlen > 0 && nlen <= 512 && strlen(name) == nlen, 3, "invalid object name");
  const char *token_name = luaL_optstring(L, 4, NULL);
  SqlServerOptions options = read_options(L);
  SqlDefinition *d = lua_newuserdata(L, sizeof(*d)); memset(d, 0, sizeof(*d));
  luaL_setmetatable(L, "anvil.sql_definition");
  AnvilWorkerCancelToken *token = token_name ? anvil_worker_cancel_token_open(token_name) : NULL;
  luaL_argcheck(L, !token_name || token, 4, "cancel token unavailable");
  int ok = sql_definition_read(&options, schema, name, token ? query_cancelled : NULL, token, d);
  if (token) anvil_worker_cancel_token_release(token);
  if (!ok) {
    lua_pushnil(L); lua_pushstring(L, d->error); sql_definition_free(d); return 2;
  }
  lua_newtable(L);
  text(L, "source", d->source_sql);
  if (d->create_sql) text(L, "create", d->create_sql);
  if (d->alter_sql) text(L, "alter", d->alter_sql);
  if (d->select_sql) text(L, "select", d->select_sql);
  if (d->insert_sql) text(L, "insert", d->insert_sql);
  if (d->update_sql) text(L, "update", d->update_sql);
  if (d->delete_sql) text(L, "delete", d->delete_sql);
  sql_definition_free(d); return 1;
}
static int module_script(lua_State *L) {
  size_t length; const char *source = luaL_checklstring(L, 1, &length);
  const char *mode = luaL_checkstring(L, 2);
  luaL_argcheck(L, !strcmp(mode, "CREATE") || !strcmp(mode, "ALTER"), 2, "expected CREATE or ALTER");
  char *script = sql_module_script(source, length, !strcmp(mode, "ALTER"));
  if (!script) lua_pushnil(L); else { lua_pushstring(L, script); free(script); }
  return 1;
}
static int format_sql(lua_State *L) {
  size_t length, indent_length;
  const char *source = luaL_checklstring(L, 1, &length);
  const char *indent = luaL_checklstring(L, 2, &indent_length);
  char *out;
  size_t out_length;
  if (!sql_format(source, length, indent, indent_length, &out, &out_length)) {
    lua_pushnil(L); lua_pushliteral(L, "The SQL is too large to format."); return 2;
  }
  lua_pushlstring(L, out, out_length);
  free(out);
  return 1;
}
int luaopen_sql_server_native(lua_State *L) {
  luaL_newmetatable(L, "anvil.sql_definition");
  lua_pushcfunction(L, definition_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  luaL_newmetatable(L, "anvil.sql_catalog");
  lua_pushcfunction(L, catalog_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  luaL_newmetatable(L, "anvil.sql_query");
  lua_pushcfunction(L, query_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  const luaL_Reg functions[] = { {"context", context}, {"read_schema", read_schema}, {"read_columns", read_columns}, {"execute", execute_query},
    {"read_definition", read_definition}, {"module_script", module_script}, {"format", format_sql},
    {"end_transaction", end_transaction}, {"close_session", close_session}, {NULL, NULL} };
  luaL_newlib(L, functions); return 1;
}
