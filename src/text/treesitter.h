#ifndef ANVIL_TEXT_TREESITTER_H
#define ANVIL_TEXT_TREESITTER_H

#include "text/buffer_manager.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct NativeTreeSitter NativeTreeSitter;

typedef struct NativeTreeSitterHighlightSpan {
  size_t start_offset;
  size_t end_offset;
  char *capture_name;
} NativeTreeSitterHighlightSpan;

NativeTreeSitter *native_treesitter_new(Buffer *buffer, const char *language_name);
void native_treesitter_free(NativeTreeSitter *state);

bool native_treesitter_set_language(NativeTreeSitter *state, Buffer *buffer, const char *language_name);
const char *native_treesitter_language_name(const NativeTreeSitter *state);
const char *native_treesitter_root_kind(const NativeTreeSitter *state);
bool native_treesitter_reparse(NativeTreeSitter *state, Buffer *buffer);
bool native_treesitter_after_edit(NativeTreeSitter *state, Buffer *buffer, const BatchEditResult *result);
bool native_treesitter_after_snap(NativeTreeSitter *state, Buffer *buffer);

NativeTreeSitterHighlightSpan *native_treesitter_highlights(
  NativeTreeSitter *state,
  size_t start_offset,
  size_t end_offset,
  size_t *count_out
);
void native_treesitter_highlights_free(NativeTreeSitterHighlightSpan *spans, size_t count);

#endif
