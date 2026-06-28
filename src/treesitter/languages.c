#include "languages.h"

#include <string.h>

const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_odin(void);

static const AnvilTSLanguage anvil_ts_languages[] = {
  { "c", "0.24.2", tree_sitter_c },
  { "cpp", "0.23.4", tree_sitter_cpp },
  { "odin", "1.3.0", tree_sitter_odin },
};

size_t anvil_ts_language_count(void) {
  return sizeof(anvil_ts_languages) / sizeof(anvil_ts_languages[0]);
}

const AnvilTSLanguage *anvil_ts_language_at(size_t index) {
  if (index >= anvil_ts_language_count()) return NULL;
  return &anvil_ts_languages[index];
}

const AnvilTSLanguage *anvil_ts_language_by_id(const char *id) {
  if (!id) return NULL;
  for (size_t i = 0; i < anvil_ts_language_count(); i++) {
    if (strcmp(anvil_ts_languages[i].id, id) == 0) return &anvil_ts_languages[i];
  }
  return NULL;
}

const TSLanguage *anvil_ts_language_ptr(const AnvilTSLanguage *language) {
  if (!language || !language->language_fn) return NULL;
  return language->language_fn();
}

bool anvil_ts_language_is_compatible(const AnvilTSLanguage *language) {
  const TSLanguage *ts_language = anvil_ts_language_ptr(language);
  if (!ts_language) return false;
  uint32_t abi = ts_language_abi_version(ts_language);
  return abi >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION &&
         abi <= TREE_SITTER_LANGUAGE_VERSION;
}
