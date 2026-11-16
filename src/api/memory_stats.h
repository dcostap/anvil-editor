#ifndef ANVIL_LUA_MEMORY_STATS_H
#define ANVIL_LUA_MEMORY_STATS_H
#include <lua.h>
#include <stdbool.h>
void anvil_lua_memory_register(lua_State *L, const char *name);
void anvil_lua_memory_sample(lua_State *L, bool force);
int anvil_lua_memory_stats(lua_State *L);
#endif
