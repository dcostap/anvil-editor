#include "memory_stats.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <SDL3/SDL.h>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#endif

static struct {
  atomic_uint_fast64_t bytes, peak, objects;
} counters[ANVIL_MEMORY_CATEGORY_COUNT];
static SDL_SpinLock lua_lock;
static AnvilLuaMemory lua_states[ANVIL_MEMORY_LUA_LIMIT];
static uint64_t lua_sequence, lua_omitted;

const char *anvil_memory_category_name(AnvilMemoryCategory category) {
  static const char *names[] = { "treesitter", "ts_text_snapshots", "ts_file_records", "ts_index_snapshots", "font_glyphs" };
  return names[category];
}

const char *anvil_memory_category_basis(AnvilMemoryCategory category) {
  return category == ANVIL_MEMORY_TREESITTER ? "allocator_usable" : "owned_estimate";
}

void anvil_memory_account(AnvilMemoryCategory category, int64_t bytes, int64_t objects) {
  uint64_t current = atomic_fetch_add_explicit(&counters[category].bytes, bytes, memory_order_relaxed) + bytes;
  atomic_fetch_add_explicit(&counters[category].objects, objects, memory_order_relaxed);
  uint64_t peak = atomic_load_explicit(&counters[category].peak, memory_order_relaxed);
  while (current > peak && !atomic_compare_exchange_weak_explicit(
      &counters[category].peak, &peak, current, memory_order_relaxed, memory_order_relaxed)) {}
}

AnvilMemoryCounter anvil_memory_counter(AnvilMemoryCategory category) {
  AnvilMemoryCounter result;
  result.bytes = atomic_load_explicit(&counters[category].bytes, memory_order_relaxed);
  result.peak_bytes = atomic_load_explicit(&counters[category].peak, memory_order_relaxed);
  result.objects = atomic_load_explicit(&counters[category].objects, memory_order_relaxed);
  /* An allocation can race the reader between its current and peak loads. */
  if (result.peak_bytes < result.bytes) result.peak_bytes = result.bytes;
  return result;
}

AnvilProcessMemory anvil_memory_process(void) {
  AnvilProcessMemory result = {0};
#ifdef _WIN32
  /* PROCESS_MEMORY_COUNTERS_EX2 is absent from some MinGW headers. */
  struct {
    PROCESS_MEMORY_COUNTERS_EX base;
    SIZE_T PrivateWorkingSetSize;
    ULONG64 SharedCommitUsage;
  } memory = { .base.cb = sizeof(memory) };
  if (K32GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory))) {
    result.available = true;
    result.private_commit_bytes = memory.base.PrivateUsage;
    result.working_set_bytes = memory.base.WorkingSetSize;
    result.private_working_set_bytes = memory.PrivateWorkingSetSize;
  }
#endif
  return result;
}

uint64_t anvil_memory_lua_register(const char *name) {
  uint64_t id = 0;
  SDL_LockSpinlock(&lua_lock);
  for (size_t i = 0; i < ANVIL_MEMORY_LUA_LIMIT; i++) {
    if (lua_states[i].id) continue;
    lua_states[i] = (AnvilLuaMemory){ .id = ++lua_sequence };
    SDL_strlcpy(lua_states[i].name, name, sizeof(lua_states[i].name));
    /* Keep each sample on one log line. */
    for (char *p = lua_states[i].name; *p; p++) if ((unsigned char)*p < 32) *p = '?';
    id = lua_states[i].id;
    break;
  }
  if (!id) lua_omitted++;
  SDL_UnlockSpinlock(&lua_lock);
  return id;
}

void anvil_memory_lua_sample(uint64_t id, uint64_t bytes) {
  if (!id) return;
  uint64_t now = SDL_GetTicks();
  SDL_LockSpinlock(&lua_lock);
  for (size_t i = 0; i < ANVIL_MEMORY_LUA_LIMIT; i++) {
    if (lua_states[i].id != id) continue;
    lua_states[i].bytes = bytes;
    lua_states[i].sampled_ms = now;
    break;
  }
  SDL_UnlockSpinlock(&lua_lock);
}

void anvil_memory_lua_remove(uint64_t id) {
  SDL_LockSpinlock(&lua_lock);
  if (!id) { if (lua_omitted) lua_omitted--; }
  else for (size_t i = 0; i < ANVIL_MEMORY_LUA_LIMIT; i++) {
    if (lua_states[i].id == id) { lua_states[i] = (AnvilLuaMemory){0}; break; }
  }
  SDL_UnlockSpinlock(&lua_lock);
}

size_t anvil_memory_lua_read(AnvilLuaMemory *rows, size_t capacity, uint64_t *omitted) {
  size_t count = 0;
  SDL_LockSpinlock(&lua_lock);
  *omitted = lua_omitted;
  for (size_t i = 0; i < ANVIL_MEMORY_LUA_LIMIT; i++) {
    if (!lua_states[i].id) continue;
    if (count < capacity) rows[count++] = lua_states[i];
    else (*omitted)++;
  }
  SDL_UnlockSpinlock(&lua_lock);
  return count;
}

#ifdef _WIN32
static HANDLE reporter, stop_event;
static DWORD WINAPI memory_reporter(void *unused) {
  (void)unused;
  uint64_t sequence = 0;
  DWORD delay = 5000;
  while (WaitForSingleObject(stop_event, delay) == WAIT_TIMEOUT) {
    delay = 30000;
    uint64_t sample = ++sequence;
    AnvilProcessMemory process = anvil_memory_process();
    SDL_Log("Memory process: v=1 sample=%llu available=%d private_commit_bytes=%llu working_set_bytes=%llu private_working_set_bytes=%llu",
      (unsigned long long)sample, process.available,
      (unsigned long long)process.private_commit_bytes, (unsigned long long)process.working_set_bytes,
      (unsigned long long)process.private_working_set_bytes);
    for (int i = 0; i < ANVIL_MEMORY_CATEGORY_COUNT; i++) {
      AnvilMemoryCounter counter = anvil_memory_counter(i);
      SDL_Log("Memory native: sample=%llu category=%s basis=%s bytes=%llu peak_bytes=%llu objects=%llu",
        (unsigned long long)sample, anvil_memory_category_name(i),
        anvil_memory_category_basis(i),
        (unsigned long long)counter.bytes, (unsigned long long)counter.peak_bytes,
        (unsigned long long)counter.objects);
    }
    AnvilLuaMemory rows[ANVIL_MEMORY_LUA_LIMIT];
    uint64_t omitted;
    size_t count = anvil_memory_lua_read(rows, ANVIL_MEMORY_LUA_LIMIT, &omitted);
    uint64_t now = SDL_GetTicks();
    SDL_Log("Memory Lua states: sample=%llu states=%llu omitted=%llu", (unsigned long long)sample,
      (unsigned long long)count, (unsigned long long)omitted);
    for (size_t i = 0; i < count; i++) {
      SDL_Log("Memory Lua: sample=%llu state=%llu bytes=%llu age_ms=%llu name=%s",
        (unsigned long long)sample, (unsigned long long)rows[i].id, (unsigned long long)rows[i].bytes,
        (unsigned long long)(now - rows[i].sampled_ms), rows[i].name);
    }
  }
  return 0;
}
#endif

void anvil_memory_log_start(void) {
#ifdef _WIN32
  if (reporter) return;
  stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (stop_event) reporter = CreateThread(NULL, 0, memory_reporter, NULL, 0, NULL);
  if (!reporter) {
    if (stop_event) CloseHandle(stop_event);
    stop_event = NULL;
    SDL_Log("Memory diagnostics: reporter could not start");
    return;
  }
  atexit(anvil_memory_log_stop);
#endif
}

void anvil_memory_log_stop(void) {
#ifdef _WIN32
  if (!reporter) return;
  SetEvent(stop_event);
  WaitForSingleObject(reporter, INFINITE);
  CloseHandle(reporter);
  CloseHandle(stop_event);
  reporter = stop_event = NULL;
#endif
}
