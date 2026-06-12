#ifndef ANVIL_TEXT_DECORATIONS_H
#define ANVIL_TEXT_DECORATIONS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum NativeDecorationKind {
  NATIVE_DECORATION_RANGE,
  NATIVE_DECORATION_LINE,
  NATIVE_DECORATION_LINE_HINT,
} NativeDecorationKind;

typedef enum NativeDecorationPlane {
  NATIVE_DECORATION_LINE_BACKGROUND,
  NATIVE_DECORATION_BACKGROUND,
  NATIVE_DECORATION_GUTTER,
  NATIVE_DECORATION_OVERVIEW,
  NATIVE_DECORATION_UNDERLINE,
  NATIVE_DECORATION_OUTLINE,
  NATIVE_DECORATION_TEXT,
  NATIVE_DECORATION_HINT,
  NATIVE_DECORATION_OVERLAY,
} NativeDecorationPlane;

typedef struct NativeDecoration {
  NativeDecorationKind kind;
  NativeDecorationPlane plane;
  size_t start_offset;
  size_t end_offset;
  size_t line_first;
  size_t line_last;
  int priority;
  unsigned int flags;
  char *style_key;
  char *text;
  size_t insertion_index;
} NativeDecoration;

typedef struct NativeDecorationInput {
  NativeDecorationKind kind;
  NativeDecorationPlane plane;
  size_t start_offset;
  size_t end_offset;
  size_t line_first;
  size_t line_last;
  int priority;
  unsigned int flags;
  const char *style_key;
  const char *text;
} NativeDecorationInput;

typedef struct NativeDecorationSet {
  char *producer;
  NativeDecoration *items;
  size_t count;
  bool clear_on_edit;
  uint64_t generation;
} NativeDecorationSet;

typedef struct NativeDecorationStore {
  NativeDecorationSet *sets;
  size_t count;
  size_t capacity;
  uint64_t generation;
  size_t next_insertion_index;
} NativeDecorationStore;

typedef struct NativeDecorationQueryItem {
  const char *producer;
  uint64_t generation;
  bool clear_on_edit;
  const NativeDecoration *decoration;
} NativeDecorationQueryItem;

void native_decoration_store_init(NativeDecorationStore *store);
void native_decoration_store_dispose(NativeDecorationStore *store);
void native_decoration_store_clear_all(NativeDecorationStore *store);
bool native_decoration_store_set(
  NativeDecorationStore *store,
  const char *producer,
  const NativeDecorationInput *items,
  size_t count,
  bool clear_on_edit
);
bool native_decoration_store_clear(NativeDecorationStore *store, const char *producer);
void native_decoration_store_after_edit(NativeDecorationStore *store);
uint64_t native_decoration_store_generation(const NativeDecorationStore *store);
NativeDecorationQueryItem *native_decoration_store_query(
  const NativeDecorationStore *store,
  size_t start_offset,
  size_t end_offset,
  size_t start_line,
  size_t end_line,
  const char *producer,
  bool filter_producer,
  NativeDecorationPlane plane,
  bool filter_plane,
  NativeDecorationKind kind,
  bool filter_kind,
  size_t *count_out
);
void native_decoration_store_query_free(NativeDecorationQueryItem *items);

const char *native_decoration_kind_name(NativeDecorationKind kind);
const char *native_decoration_plane_name(NativeDecorationPlane plane);

#endif
