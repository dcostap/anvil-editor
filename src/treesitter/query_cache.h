#ifndef ANVIL_TREESITTER_QUERY_CACHE_H
#define ANVIL_TREESITTER_QUERY_CACHE_H

#include <stdbool.h>
#include <stdint.h>

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilTSQueryCacheResult {
  const TSQuery *query;
  const char *error;
  uint64_t fingerprint;
  bool cache_hit;
  bool failed;
} AnvilTSQueryCacheResult;

bool anvil_ts_query_cache_get(
  const TSLanguage *language,
  const char *kind,
  const char *source,
  uint32_t source_len,
  AnvilTSQueryCacheResult *result
);

#ifdef __cplusplus
}
#endif

#endif
