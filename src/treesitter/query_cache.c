#include "query_cache.h"

#include <SDL3/SDL.h>

#include <stdio.h>
#include <string.h>

typedef struct AnvilTSQueryCacheEntry {
  const TSLanguage *language;
  uint32_t language_abi;
  char *kind;
  char *source;
  uint32_t source_len;
  uint64_t fingerprint;
  TSQuery *query;
  char *error;
  struct AnvilTSQueryCacheEntry *next;
} AnvilTSQueryCacheEntry;

static SDL_InitState cache_init;
static SDL_Mutex *cache_mutex;
static AnvilTSQueryCacheEntry *cache_entries;

static SDL_Mutex *query_cache_mutex(void) {
  if (SDL_ShouldInit(&cache_init)) {
    cache_mutex = SDL_CreateMutex();
    SDL_SetInitialized(&cache_init, cache_mutex != NULL);
  }
  return cache_mutex;
}

static uint64_t fingerprint_bytes(const char *kind, const char *source, uint32_t source_len) {
  uint64_t hash = UINT64_C(1469598103934665603);
  const unsigned char *kind_bytes = (const unsigned char *)(kind ? kind : "");
  for (size_t i = 0; kind_bytes[i]; i++) {
    hash ^= kind_bytes[i];
    hash *= UINT64_C(1099511628211);
  }
  hash ^= 0xff;
  hash *= UINT64_C(1099511628211);
  for (uint32_t i = 0; i < source_len; i++) {
    hash ^= (unsigned char)source[i];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static char *copy_bytes(const char *source, size_t len) {
  if (len == SIZE_MAX) return NULL;
  char *copy = (char *)SDL_malloc(len + 1);
  if (!copy) return NULL;
  if (len) memcpy(copy, source, len);
  copy[len] = '\0';
  return copy;
}

static bool entry_matches(
  const AnvilTSQueryCacheEntry *entry,
  const TSLanguage *language,
  uint32_t language_abi,
  const char *kind,
  const char *source,
  uint32_t source_len,
  uint64_t fingerprint
) {
  return entry->language == language && entry->language_abi == language_abi &&
    entry->fingerprint == fingerprint && entry->source_len == source_len &&
    strcmp(entry->kind, kind) == 0 &&
    (source_len == 0 || memcmp(entry->source, source, source_len) == 0);
}

bool anvil_ts_query_cache_get(
  const TSLanguage *language,
  const char *kind,
  const char *source,
  uint32_t source_len,
  AnvilTSQueryCacheResult *result
) {
  if (result) memset(result, 0, sizeof(*result));
  if (!language || !kind || !source || source_len == 0 || !result) return false;
  SDL_Mutex *mutex = query_cache_mutex();
  if (!mutex) return false;

  uint32_t language_abi = ts_language_abi_version(language);
  uint64_t fingerprint = fingerprint_bytes(kind, source, source_len);
  SDL_LockMutex(mutex);
  for (AnvilTSQueryCacheEntry *entry = cache_entries; entry; entry = entry->next) {
    if (!entry_matches(entry, language, language_abi, kind, source, source_len, fingerprint)) continue;
    result->query = entry->query;
    result->error = entry->error;
    result->fingerprint = fingerprint;
    result->cache_hit = true;
    result->failed = entry->query == NULL;
    SDL_UnlockMutex(mutex);
    return true;
  }

  AnvilTSQueryCacheEntry *entry = (AnvilTSQueryCacheEntry *)SDL_calloc(1, sizeof(*entry));
  if (!entry) {
    SDL_UnlockMutex(mutex);
    return false;
  }
  entry->language = language;
  entry->language_abi = language_abi;
  entry->kind = copy_bytes(kind, strlen(kind));
  entry->source = copy_bytes(source, source_len);
  entry->source_len = source_len;
  entry->fingerprint = fingerprint;
  if (!entry->kind || !entry->source) {
    SDL_free(entry->kind);
    SDL_free(entry->source);
    SDL_free(entry);
    SDL_UnlockMutex(mutex);
    return false;
  }

  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  entry->query = ts_query_new(language, source, source_len, &error_offset, &error_type);
  if (!entry->query) {
    char message[256];
    snprintf(message, sizeof(message), "Tree-sitter %s query error %d at byte %u",
      kind, (int)error_type, (unsigned)error_offset);
    entry->error = copy_bytes(message, strlen(message));
    if (!entry->error) {
      SDL_free(entry->kind);
      SDL_free(entry->source);
      SDL_free(entry);
      SDL_UnlockMutex(mutex);
      return false;
    }
  }

  entry->next = cache_entries;
  cache_entries = entry;
  result->query = entry->query;
  result->error = entry->error;
  result->fingerprint = fingerprint;
  result->failed = entry->query == NULL;
  SDL_UnlockMutex(mutex);
  return true;
}
