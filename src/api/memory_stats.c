#include "memory_stats.h"
#include "../memory_stats.h"
#include <lauxlib.h>
#include <SDL3/SDL.h>

static char registry_key;
typedef struct { uint64_t id, next_ms; } LuaMemory;

static uint64_t lua_bytes(lua_State *L) {
  return (uint64_t)lua_gc(L, LUA_GCCOUNT, 0) * 1024 + lua_gc(L, LUA_GCCOUNTB, 0);
}

static int release_sample(lua_State *L) {
  LuaMemory *state = lua_touserdata(L, 1);
  anvil_memory_lua_remove(state->id);
  return 0;
}

void anvil_lua_memory_register(lua_State *L, const char *name) {
  lua_pushlightuserdata(L, &registry_key);
  LuaMemory *state = lua_newuserdata(L, sizeof(*state));
  state->id = anvil_memory_lua_register(name);
  state->next_ms = SDL_GetTicks() + 5000;
  if (luaL_newmetatable(L, "Anvil.MemorySample")) {
    lua_pushcfunction(L, release_sample);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_rawset(L, LUA_REGISTRYINDEX);
  anvil_memory_lua_sample(state->id, lua_bytes(L));
}

void anvil_lua_memory_sample(lua_State *L, bool force) {
  /* Only the owner thread calls this. No background thread reads Lua objects. */
  lua_pushlightuserdata(L, &registry_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  LuaMemory *state = lua_touserdata(L, -1);
  uint64_t now = SDL_GetTicks();
  if (state && (force || now >= state->next_ms)) {
    state->next_ms = now + 5000;
    anvil_memory_lua_sample(state->id, lua_bytes(L));
  }
  lua_pop(L, 1);
}

static void field(lua_State *L, const char *name, uint64_t value) {
  lua_pushnumber(L, (lua_Number)value);
  lua_setfield(L, -2, name);
}

int anvil_lua_memory_stats(lua_State *L) {
  uint64_t bytes = lua_bytes(L);
  anvil_lua_memory_sample(L, true);
  lua_newtable(L);
  field(L, "lua_bytes", bytes);
  lua_newtable(L);
  AnvilProcessMemory process = anvil_memory_process();
  if (process.available) {
    field(L, "private_commit_bytes", process.private_commit_bytes);
    field(L, "working_set_bytes", process.working_set_bytes);
    field(L, "private_working_set_bytes", process.private_working_set_bytes);
  }
  lua_setfield(L, -2, "process");
  lua_newtable(L);
  for (int i = 0; i < ANVIL_MEMORY_CATEGORY_COUNT; i++) {
    AnvilMemoryCounter counter = anvil_memory_counter(i);
    lua_newtable(L);
    lua_pushstring(L, anvil_memory_category_basis(i));
    lua_setfield(L, -2, "basis");
    field(L, "bytes", counter.bytes);
    field(L, "peak_bytes", counter.peak_bytes);
    field(L, "objects", counter.objects);
    lua_setfield(L, -2, anvil_memory_category_name(i));
  }
  lua_setfield(L, -2, "categories");
  AnvilLuaMemory rows[ANVIL_MEMORY_LUA_LIMIT];
  uint64_t omitted;
  size_t count = anvil_memory_lua_read(rows, ANVIL_MEMORY_LUA_LIMIT, &omitted);
  uint64_t now = SDL_GetTicks();
  field(L, "lua_states_omitted", omitted);
  lua_newtable(L);
  for (size_t i = 0; i < count; i++) {
    lua_newtable(L);
    field(L, "id", rows[i].id);
    field(L, "bytes", rows[i].bytes);
    field(L, "age_ms", now - rows[i].sampled_ms);
    lua_pushstring(L, rows[i].name);
    lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, (int)i + 1);
  }
  lua_setfield(L, -2, "lua_states");
  return 1;
}
