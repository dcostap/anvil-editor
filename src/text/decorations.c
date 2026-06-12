#include "text/decorations.h"

#include <stdlib.h>
#include <string.h>

static char *decoration_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

static void decoration_free(NativeDecoration *decoration) {
  if (!decoration) return;
  free(decoration->style_key);
  free(decoration->text);
  memset(decoration, 0, sizeof(*decoration));
}

static void decoration_set_free(NativeDecorationSet *set) {
  if (!set) return;
  free(set->producer);
  for (size_t i = 0; i < set->count; ++i) decoration_free(&set->items[i]);
  free(set->items);
  memset(set, 0, sizeof(*set));
}

void native_decoration_store_init(NativeDecorationStore *store) {
  if (!store) return;
  memset(store, 0, sizeof(*store));
}

void native_decoration_store_dispose(NativeDecorationStore *store) {
  if (!store) return;
  native_decoration_store_clear_all(store);
  free(store->sets);
  memset(store, 0, sizeof(*store));
}

void native_decoration_store_clear_all(NativeDecorationStore *store) {
  if (!store) return;
  for (size_t i = 0; i < store->count; ++i) decoration_set_free(&store->sets[i]);
  store->count = 0;
  store->generation += 1;
}

static NativeDecorationSet *find_set(NativeDecorationStore *store, const char *producer) {
  if (!store || !producer) return NULL;
  for (size_t i = 0; i < store->count; ++i) {
    if (store->sets[i].producer && strcmp(store->sets[i].producer, producer) == 0) return &store->sets[i];
  }
  return NULL;
}

static bool ensure_set_capacity(NativeDecorationStore *store) {
  if (store->count < store->capacity) return true;
  size_t cap = store->capacity ? store->capacity * 2 : 4;
  NativeDecorationSet *sets = (NativeDecorationSet *) realloc(store->sets, cap * sizeof(NativeDecorationSet));
  if (!sets) return false;
  memset(sets + store->capacity, 0, (cap - store->capacity) * sizeof(NativeDecorationSet));
  store->sets = sets;
  store->capacity = cap;
  return true;
}

static bool copy_decoration(NativeDecoration *out, const NativeDecorationInput *in, size_t insertion_index) {
  memset(out, 0, sizeof(*out));
  out->kind = in->kind;
  out->plane = in->plane;
  out->start_offset = in->start_offset;
  out->end_offset = in->end_offset;
  out->line_first = in->line_first;
  out->line_last = in->line_last;
  out->priority = in->priority;
  out->flags = in->flags;
  out->insertion_index = insertion_index;
  if (in->style_key) {
    out->style_key = decoration_strdup(in->style_key);
    if (!out->style_key) return false;
  }
  if (in->text) {
    out->text = decoration_strdup(in->text);
    if (!out->text) {
      decoration_free(out);
      return false;
    }
  }
  return true;
}

bool native_decoration_store_set(
  NativeDecorationStore *store,
  const char *producer,
  const NativeDecorationInput *items,
  size_t count,
  bool clear_on_edit
) {
  if (!store || !producer || producer[0] == '\0' || (count > 0 && !items)) return false;

  NativeDecoration *copied = NULL;
  if (count > 0) {
    copied = (NativeDecoration *) calloc(count, sizeof(NativeDecoration));
    if (!copied) return false;
    for (size_t i = 0; i < count; ++i) {
      if (!copy_decoration(&copied[i], &items[i], store->next_insertion_index + i)) {
        for (size_t j = 0; j <= i; ++j) decoration_free(&copied[j]);
        free(copied);
        return false;
      }
    }
  }

  NativeDecorationSet *set = find_set(store, producer);
  if (!set) {
    if (!ensure_set_capacity(store)) {
      for (size_t i = 0; i < count; ++i) decoration_free(&copied[i]);
      free(copied);
      return false;
    }
    set = &store->sets[store->count++];
    memset(set, 0, sizeof(*set));
    set->producer = decoration_strdup(producer);
    if (!set->producer) {
      store->count -= 1;
      for (size_t i = 0; i < count; ++i) decoration_free(&copied[i]);
      free(copied);
      return false;
    }
  } else {
    for (size_t i = 0; i < set->count; ++i) decoration_free(&set->items[i]);
    free(set->items);
  }

  set->items = copied;
  set->count = count;
  set->clear_on_edit = clear_on_edit;
  set->generation = store->generation + 1;
  store->next_insertion_index += count;
  store->generation += 1;
  return true;
}

bool native_decoration_store_clear(NativeDecorationStore *store, const char *producer) {
  if (!store || !producer) return false;
  size_t out = 0;
  bool removed = false;
  for (size_t i = 0; i < store->count; ++i) {
    if (store->sets[i].producer && strcmp(store->sets[i].producer, producer) == 0) {
      decoration_set_free(&store->sets[i]);
      removed = true;
    } else {
      if (out != i) store->sets[out] = store->sets[i];
      out += 1;
    }
  }
  if (removed) {
    store->count = out;
    store->generation += 1;
  }
  return true;
}

void native_decoration_store_after_edit(NativeDecorationStore *store) {
  if (!store) return;
  store->generation += 1;
  size_t out = 0;
  for (size_t i = 0; i < store->count; ++i) {
    if (store->sets[i].clear_on_edit) {
      decoration_set_free(&store->sets[i]);
    } else {
      if (out != i) store->sets[out] = store->sets[i];
      out += 1;
    }
  }
  store->count = out;
}

uint64_t native_decoration_store_generation(const NativeDecorationStore *store) {
  return store ? store->generation : 0;
}

static bool decoration_intersects(
  const NativeDecoration *decoration,
  size_t start_offset,
  size_t end_offset,
  size_t start_line,
  size_t end_line
) {
  if (!decoration) return false;
  if (decoration->kind == NATIVE_DECORATION_RANGE) {
    return decoration->end_offset > start_offset && decoration->start_offset < end_offset;
  }
  return decoration->line_last >= start_line && decoration->line_first <= end_line;
}

static int compare_query_items(const void *a, const void *b) {
  const NativeDecorationQueryItem *ia = (const NativeDecorationQueryItem *) a;
  const NativeDecorationQueryItem *ib = (const NativeDecorationQueryItem *) b;
  const NativeDecoration *da = ia->decoration;
  const NativeDecoration *db = ib->decoration;
  if (da->plane < db->plane) return -1;
  if (da->plane > db->plane) return 1;
  if (da->priority < db->priority) return -1;
  if (da->priority > db->priority) return 1;
  int producer_cmp = strcmp(ia->producer ? ia->producer : "", ib->producer ? ib->producer : "");
  if (producer_cmp != 0) return producer_cmp;
  size_t aa = da->kind == NATIVE_DECORATION_RANGE ? da->start_offset : da->line_first;
  size_t ab = db->kind == NATIVE_DECORATION_RANGE ? db->start_offset : db->line_first;
  if (aa < ab) return -1;
  if (aa > ab) return 1;
  if (da->insertion_index < db->insertion_index) return -1;
  if (da->insertion_index > db->insertion_index) return 1;
  return 0;
}

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
) {
  if (count_out) *count_out = 0;
  if (!store) return NULL;

  size_t capacity = 0;
  size_t count = 0;
  NativeDecorationQueryItem *items = NULL;

  for (size_t s = 0; s < store->count; ++s) {
    const NativeDecorationSet *set = &store->sets[s];
    if (filter_producer && (!set->producer || strcmp(set->producer, producer) != 0)) continue;
    for (size_t i = 0; i < set->count; ++i) {
      const NativeDecoration *decoration = &set->items[i];
      if (filter_plane && decoration->plane != plane) continue;
      if (filter_kind && decoration->kind != kind) continue;
      if (!decoration_intersects(decoration, start_offset, end_offset, start_line, end_line)) continue;
      if (count == capacity) {
        size_t cap = capacity ? capacity * 2 : 16;
        NativeDecorationQueryItem *new_items = (NativeDecorationQueryItem *) realloc(items, cap * sizeof(NativeDecorationQueryItem));
        if (!new_items) {
          free(items);
          return NULL;
        }
        items = new_items;
        capacity = cap;
      }
      items[count].producer = set->producer;
      items[count].generation = set->generation;
      items[count].clear_on_edit = set->clear_on_edit;
      items[count].decoration = decoration;
      count += 1;
    }
  }

  if (count > 1) qsort(items, count, sizeof(NativeDecorationQueryItem), compare_query_items);
  if (count_out) *count_out = count;
  return items;
}

void native_decoration_store_query_free(NativeDecorationQueryItem *items) {
  free(items);
}

const char *native_decoration_kind_name(NativeDecorationKind kind) {
  switch (kind) {
    case NATIVE_DECORATION_RANGE: return "range";
    case NATIVE_DECORATION_LINE: return "line";
    case NATIVE_DECORATION_LINE_HINT: return "line-hint";
  }
  return "unknown";
}

const char *native_decoration_plane_name(NativeDecorationPlane plane) {
  switch (plane) {
    case NATIVE_DECORATION_LINE_BACKGROUND: return "line-background";
    case NATIVE_DECORATION_BACKGROUND: return "background";
    case NATIVE_DECORATION_GUTTER: return "gutter";
    case NATIVE_DECORATION_OVERVIEW: return "overview";
    case NATIVE_DECORATION_UNDERLINE: return "underline";
    case NATIVE_DECORATION_OUTLINE: return "outline";
    case NATIVE_DECORATION_TEXT: return "text";
    case NATIVE_DECORATION_HINT: return "hint";
    case NATIVE_DECORATION_OVERLAY: return "overlay";
  }
  return "unknown";
}
