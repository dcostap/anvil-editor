#ifndef ANVIL_TREESITTER_LANGUAGES_H
#define ANVIL_TREESITTER_LANGUAGES_H

#include <stdbool.h>
#include <stddef.h>

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const TSLanguage *(*AnvilTSLanguageFn)(void);

typedef struct AnvilTSLanguage {
  const char *id;
  const char *semantic_version;
  AnvilTSLanguageFn language_fn;
} AnvilTSLanguage;

size_t anvil_ts_language_count(void);
const AnvilTSLanguage *anvil_ts_language_at(size_t index);
const AnvilTSLanguage *anvil_ts_language_by_id(const char *id);
const TSLanguage *anvil_ts_language_ptr(const AnvilTSLanguage *language);
bool anvil_ts_language_is_compatible(const AnvilTSLanguage *language);

#ifdef __cplusplus
}
#endif

#endif
