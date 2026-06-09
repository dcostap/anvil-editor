#ifndef ANVIL_TEXT_TREESITTER_REGISTRY_H
#define ANVIL_TEXT_TREESITTER_REGISTRY_H

#include <stddef.h>

#include <tree_sitter/api.h>

typedef const TSLanguage *(*NativeTreeSitterLanguageFn)(void);

typedef struct NativeTreeSitterCaptureStyle {
  const char *capture;
  const char *style;
  int priority;
} NativeTreeSitterCaptureStyle;

typedef struct NativeTreeSitterLanguageDef {
  const char *id;
  NativeTreeSitterLanguageFn language_fn;
  const char *highlight_query_asset;
  const char *const *extensions;
  size_t extension_count;
  const NativeTreeSitterCaptureStyle *capture_styles;
  size_t capture_style_count;
} NativeTreeSitterLanguageDef;

size_t native_treesitter_registry_language_count(void);
const NativeTreeSitterLanguageDef *native_treesitter_registry_language_at(size_t index);
const NativeTreeSitterLanguageDef *native_treesitter_registry_find(const char *name);
size_t native_treesitter_registry_index_of(const NativeTreeSitterLanguageDef *def);
const char *native_treesitter_registry_language_for_filename(const char *filename);
void native_treesitter_registry_capture_style(
  const NativeTreeSitterLanguageDef *def,
  const char *capture,
  size_t capture_len,
  const char **style_out,
  int *priority_out
);

#endif
