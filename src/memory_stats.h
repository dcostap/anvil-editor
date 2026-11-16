#ifndef ANVIL_MEMORY_STATS_H
#define ANVIL_MEMORY_STATS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Disjoint native categories. These are not a complete process allocation census. */
typedef enum {
  ANVIL_MEMORY_TREESITTER,
  ANVIL_MEMORY_TS_TEXT,
  ANVIL_MEMORY_TS_FILES,
  ANVIL_MEMORY_TS_INDEX,
  ANVIL_MEMORY_FONT_GLYPHS,
  ANVIL_MEMORY_CATEGORY_COUNT
} AnvilMemoryCategory;

typedef struct {
  uint64_t bytes, peak_bytes, objects;
} AnvilMemoryCounter;

typedef struct {
  bool available;
  uint64_t private_commit_bytes, working_set_bytes, private_working_set_bytes;
} AnvilProcessMemory;

#define ANVIL_MEMORY_LUA_LIMIT 128
typedef struct {
  uint64_t id, bytes, sampled_ms;
  char name[64];
} AnvilLuaMemory;

const char *anvil_memory_category_name(AnvilMemoryCategory category);
const char *anvil_memory_category_basis(AnvilMemoryCategory category);
void anvil_memory_account(AnvilMemoryCategory category, int64_t bytes, int64_t objects);
AnvilMemoryCounter anvil_memory_counter(AnvilMemoryCategory category);
AnvilProcessMemory anvil_memory_process(void);
/* Samples come only from the thread that owns the Lua state. No collector runs here. */
uint64_t anvil_memory_lua_register(const char *name);
void anvil_memory_lua_sample(uint64_t id, uint64_t bytes);
void anvil_memory_lua_remove(uint64_t id);
size_t anvil_memory_lua_read(AnvilLuaMemory *rows, size_t capacity, uint64_t *omitted);
/* Windows: one process-owned reporter, stopped before SDL teardown. */
void anvil_memory_log_start(void);
void anvil_memory_log_stop(void);

#endif
