#include "api.h"
#include "../sql_context.h"
#include "../sql_server.h"
#include <string.h>

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
static int read_schema(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  SqlServerOptions options = {0};
  options.server = option(L, "server"); options.database = option(L, "database");
  options.user = option(L, "user"); options.password = option(L, "password");
  lua_getfield(L, 1, "integrated"); options.integrated = lua_toboolean(L, -1);
  lua_getfield(L, 1, "trust_certificate"); options.trust_certificate = lua_toboolean(L, -1);
  lua_getfield(L, 1, "encrypt"); options.encrypt = lua_isnil(L, -1) || lua_toboolean(L, -1);
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
int luaopen_sql_server_native(lua_State *L) {
  luaL_newmetatable(L, "anvil.sql_catalog");
  lua_pushcfunction(L, catalog_gc); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
  const luaL_Reg functions[] = { {"context", context}, {"read_schema", read_schema}, {NULL, NULL} };
  luaL_newlib(L, functions); return 1;
}
