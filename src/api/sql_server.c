#include "api.h"
#include "../sql_context.h"
#include "../sql_server.h"
#include "../sql_query.h"
#include "../sql_definition.h"
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
  text(L, "mode", out.mode == SQL_CONTEXT_TABLE ? "table" : out.mode == SQL_CONTEXT_COLUMN ? "column" : "none");
  text(L, "prefix", out.prefix); text(L, "qualifier", out.qualifier);
  lua_pushinteger(L, (lua_Integer)out.start); lua_setfield(L, -2, "start");
  lua_pushinteger(L, (lua_Integer)out.end); lua_setfield(L, -2, "end");
  lua_createtable(L, (int)out.count, 0);
  for (size_t i = 0; i < out.count; ++i) {
    lua_newtable(L);
    text(L, "schema", out.sources[i].schema); text(L, "name", out.sources[i].name); text(L, "alias", out.sources[i].alias);
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "sources");
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
  lua_newtable(L);
  int table_index = 0, column_index = 0;
  for (size_t i = 0; i < c->count; ++i) {
    SqlServerColumn *column = &c->columns[i];
    if (!i || strcmp(column->schema, c->columns[i - 1].schema) || strcmp(column->table, c->columns[i - 1].table)) {
      if (i) { lua_setfield(L, -2, "columns"); lua_rawseti(L, -2, table_index); }
      ++table_index; column_index = 0;
      lua_newtable(L);
      text(L, "schema", column->schema); text(L, "name", column->table);
      lua_newtable(L);
    }
    lua_newtable(L);
    text(L, "name", column->name); text(L, "type", column->type);
    boolean(L, "nullable", column->nullable); boolean(L, "identity", column->identity);
    boolean(L, "primary_key", column->primary_key);
    lua_rawseti(L, -2, ++column_index);
  }
  if (c->count) { lua_setfield(L, -2, "columns"); lua_rawseti(L, -2, table_index); }
  lua_setfield(L, -2, "tables");
  sql_server_catalog_free(c);
  return 1;
}
static int query_gc(lua_State *L) {
  sql_query_free(luaL_checkudata(L, 1, "anvil.sql_query")); return 0;
}
static bool query_cancelled(void *token) {
  return anvil_worker_cancel_token_cancelled(token);
}
static int execute_query(lua_State *L) {
  size_t length;
  const char *sql = luaL_checklstring(L, 2, &length);
  lua_Integer max_rows = luaL_checkinteger(L, 3), timeout = luaL_checkinteger(L, 4);
  luaL_argcheck(L, max_rows > 0 && max_rows <= 10000, 3, "invalid row limit");
  luaL_argcheck(L, timeout > 0 && timeout <= 300, 4, "invalid timeout");
  const char *token_name = luaL_optstring(L, 5, NULL);
  SqlServerOptions options = read_options(L);
  SqlQueryResult *result = lua_newuserdata(L, sizeof(*result));
  memset(result, 0, sizeof(*result));
  luaL_setmetatable(L, "anvil.sql_query");
  AnvilWorkerCancelToken *token = token_name ? anvil_worker_cancel_token_open(token_name) : NULL;
  luaL_argcheck(L, !token_name || token, 5, "cancel token unavailable");
  sql_query_execute(&options, sql, length, (unsigned)max_rows, (unsigned)timeout,
                    token ? query_cancelled : NULL, token, result);
  if (token) anvil_worker_cancel_token_release(token);
  lua_newtable(L);
  if (result->error[0]) text(L, "error", result->error);
  boolean(L, "cancelled", result->cancelled);
  boolean(L, "limited", result->limited);
  lua_newtable(L);
  int tables = 0;
  for (size_t i = 0; i < result->count; ++i) {
    SqlQueryTable *t = &result->tables[i];
    if (!t->column_count || !t->columns) continue;
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)t->column_count); lua_setfield(L, -2, "column_count");
    text(L, "missing_label", "NULL");
    if (t->truncated) text(L, "warning", "Row or cell limit reached. This result is incomplete.");
    lua_newtable(L);
    for (size_t col = 0; col < t->column_count; ++col) {
      lua_pushstring(L, t->columns[col] ? t->columns[col] : ""); lua_rawseti(L, -2, (int)col + 1);
    }
    lua_setfield(L, -2, "headers");
    lua_newtable(L);
    for (size_t row = 0; row < t->row_count; ++row) {
      lua_newtable(L);
      lua_pushinteger(L, (lua_Integer)row + 1); lua_setfield(L, -2, "source_line1");
      lua_pushinteger(L, (lua_Integer)row + 1); lua_setfield(L, -2, "source_line2");
      lua_newtable(L);
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
  lua_newtable(L);
  int counts = 0;
  for (size_t i = 0; i < result->count; ++i) {
    SqlQueryTable *t = &result->tables[i];
    if (t->column_count || t->affected_rows < 0) continue;
    char number[32]; snprintf(number, sizeof(number), "%lld", t->affected_rows);
    lua_pushstring(L, number); lua_rawseti(L, -2, ++counts);
  }
  lua_setfield(L, -2, "affected_rows");
  sql_query_free(result);
  return 1;
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
int luaopen_sql_server_native(lua_State *L) {
  luaL_newmetatable(L, "anvil.sql_definition");
  lua_pushcfunction(L, definition_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  luaL_newmetatable(L, "anvil.sql_catalog");
  lua_pushcfunction(L, catalog_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  luaL_newmetatable(L, "anvil.sql_query");
  lua_pushcfunction(L, query_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  const luaL_Reg functions[] = { {"context", context}, {"read_schema", read_schema}, {"execute", execute_query},
    {"read_definition", read_definition}, {"module_script", module_script}, {NULL, NULL} };
  luaL_newlib(L, functions); return 1;
}
