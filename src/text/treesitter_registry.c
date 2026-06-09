#include "text/treesitter_registry.h"

#include <tree_sitter/tree-sitter-c.h>

#include <ctype.h>
#include <string.h>

extern const TSLanguage *tree_sitter_c(void);

static const char *const c_extensions[] = { "c", "h" };

static const NativeTreeSitterCaptureStyle c_capture_styles[] = {
  { "keyword", "keyword", 100 },
  { "string", "string", 90 },
  { "comment", "comment", 90 },
  { "number", "number", 80 },
  { "type", "type", 75 },
  { "function", "function", 70 },
  { "property", "property", 65 },
  { "label", "label", 60 },
  { "variable", "variable", 10 },
};

static const NativeTreeSitterLanguageDef language_defs[] = {
  {
    "c",
    tree_sitter_c,
    "c/highlights.scm",
    c_extensions,
    sizeof(c_extensions) / sizeof(c_extensions[0]),
    c_capture_styles,
    sizeof(c_capture_styles) / sizeof(c_capture_styles[0]),
  },
};

static int ascii_casecmp(const char *a, const char *b) {
  if (!a || !b) return a == b ? 0 : (a ? 1 : -1);
  while (*a && *b) {
    int ca = tolower((unsigned char) *a++);
    int cb = tolower((unsigned char) *b++);
    if (ca != cb) return ca - cb;
  }
  return (unsigned char) *a - (unsigned char) *b;
}

size_t native_treesitter_registry_language_count(void) {
  return sizeof(language_defs) / sizeof(language_defs[0]);
}

const NativeTreeSitterLanguageDef *native_treesitter_registry_language_at(size_t index) {
  if (index >= native_treesitter_registry_language_count()) return NULL;
  return &language_defs[index];
}

const NativeTreeSitterLanguageDef *native_treesitter_registry_find(const char *name) {
  if (!name) return NULL;
  for (size_t i = 0; i < native_treesitter_registry_language_count(); ++i) {
    if (strcmp(language_defs[i].id, name) == 0) return &language_defs[i];
  }
  return NULL;
}

size_t native_treesitter_registry_index_of(const NativeTreeSitterLanguageDef *def) {
  if (!def) return (size_t) -1;
  for (size_t i = 0; i < native_treesitter_registry_language_count(); ++i) {
    if (&language_defs[i] == def) return i;
  }
  return (size_t) -1;
}

const char *native_treesitter_registry_language_for_filename(const char *filename) {
  if (!filename) return NULL;
  const char *last_sep = strrchr(filename, '/');
  const char *last_backslash = strrchr(filename, '\\');
  if (!last_sep || (last_backslash && last_backslash > last_sep)) last_sep = last_backslash;
  const char *name = last_sep ? last_sep + 1 : filename;
  const char *dot = strrchr(name, '.');
  if (!dot || !dot[1]) return NULL;
  const char *ext = dot + 1;

  for (size_t i = 0; i < native_treesitter_registry_language_count(); ++i) {
    const NativeTreeSitterLanguageDef *def = &language_defs[i];
    for (size_t j = 0; j < def->extension_count; ++j) {
      if (ascii_casecmp(ext, def->extensions[j]) == 0) return def->id;
    }
  }
  return NULL;
}

void native_treesitter_registry_capture_style(
  const NativeTreeSitterLanguageDef *def,
  const char *capture,
  size_t capture_len,
  const char **style_out,
  int *priority_out
) {
  if (style_out) *style_out = NULL;
  if (priority_out) *priority_out = 0;
  if (!def || !capture) return;

  for (size_t i = 0; i < def->capture_style_count; ++i) {
    const NativeTreeSitterCaptureStyle *style = &def->capture_styles[i];
    if (strlen(style->capture) == capture_len && memcmp(style->capture, capture, capture_len) == 0) {
      if (style_out) *style_out = style->style;
      if (priority_out) *priority_out = style->priority;
      return;
    }
  }

  const char *dot = memchr(capture, '.', capture_len);
  if (dot) {
    size_t base_len = (size_t) (dot - capture);
    for (size_t i = 0; i < def->capture_style_count; ++i) {
      const NativeTreeSitterCaptureStyle *style = &def->capture_styles[i];
      if (strlen(style->capture) == base_len && memcmp(style->capture, capture, base_len) == 0) {
        if (style_out) *style_out = style->style;
        if (priority_out) *priority_out = style->priority;
        return;
      }
    }
  }

  if (style_out) *style_out = "normal";
}
