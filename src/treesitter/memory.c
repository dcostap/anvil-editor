#include "memory.h"
#include "../memory_stats.h"
#include <stdlib.h>
#include <tree_sitter/api.h>
#if defined(_WIN32) || defined(__linux__)
#include <malloc.h>
#elif defined(__APPLE__)
#include <malloc/malloc.h>
#endif

static bool installed;

static size_t allocation_size(void *pointer) {
  if (!pointer) return 0;
#ifdef _WIN32
  return _msize(pointer);
#elif defined(__linux__)
  return malloc_usable_size(pointer);
#elif defined(__APPLE__)
  return malloc_size(pointer);
#else
  return 0;
#endif
}

static void *tracked_malloc(size_t size) {
  void *pointer = malloc(size);
  if (pointer) anvil_memory_account(ANVIL_MEMORY_TREESITTER, allocation_size(pointer), 1);
  return pointer;
}

static void *tracked_calloc(size_t count, size_t size) {
  void *pointer = calloc(count, size);
  if (pointer) anvil_memory_account(ANVIL_MEMORY_TREESITTER, allocation_size(pointer), 1);
  return pointer;
}

void anvil_ts_memory_free(void *pointer) {
  if (pointer && installed) anvil_memory_account(ANVIL_MEMORY_TREESITTER, -(int64_t)allocation_size(pointer), -1);
  free(pointer);
}

static void *tracked_realloc(void *pointer, size_t size) {
  if (!pointer) return tracked_malloc(size);
  if (!size) { anvil_ts_memory_free(pointer); return NULL; }
  size_t before = allocation_size(pointer);
  void *next = realloc(pointer, size);
  if (next) anvil_memory_account(ANVIL_MEMORY_TREESITTER, (int64_t)allocation_size(next) - (int64_t)before, 0);
  return next;
}

void anvil_ts_memory_init(void) {
  if (installed) return;
#if defined(_WIN32) || defined(__linux__) || defined(__APPLE__)
  installed = true;
  ts_set_allocator(tracked_malloc, tracked_calloc, tracked_realloc, anvil_ts_memory_free);
#endif
}
