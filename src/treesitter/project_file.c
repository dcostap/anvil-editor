#include "project_file.h"

#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

#define ANVIL_PROJECT_NO_OFFSET UINT32_MAX

typedef struct Slice {
  uint32_t offset;
  uint32_t length;
} Slice;

typedef struct Buffer {
  char *data;
  uint32_t length;
  uint32_t capacity;
} Buffer;

typedef struct Symbol {
  Slice name;
  Slice kind;
  Slice signature;
  Slice declaration;
  AnvilTSProjectRange range;
  AnvilTSProjectRange name_range;
  uint32_t declaration_name_start;
  uint32_t declaration_name_end;
  bool has_declaration_name_span;
  uint32_t parent;
  uint32_t depth;
  uint32_t *children;
  uint32_t child_count;
  uint32_t child_capacity;
} Symbol;

typedef struct Usage {
  Slice name;
  Slice capture;
  Slice kind;
  Slice line_text;
  AnvilTSProjectRange range;
  bool is_declaration;
} Usage;

typedef struct Group {
  uint32_t match_id;
  uint32_t item;
  uint32_t name;
  Slice kind_source;
  uint32_t *signatures;
  uint32_t signature_count;
  uint32_t signature_capacity;
} Group;

typedef struct GroupSlot {
  uint32_t match_id;
  uint32_t group_plus_one;
} GroupSlot;

typedef struct UsageSlot {
  uint64_t hash;
  uint32_t usage_plus_one;
} UsageSlot;

struct AnvilTSProjectFileResult {
  SDL_AtomicInt refcount;
  char *path;
  char *relpath;
  char *language_id;
  char *arena;
  uint32_t arena_length;
  uint32_t arena_capacity;
  Slice *interned_labels;
  uint32_t interned_label_count;
  uint32_t interned_label_capacity;
  Symbol *symbols;
  uint32_t symbol_count;
  uint32_t symbol_capacity;
  Usage *usages;
  uint32_t usage_count;
  uint32_t usage_capacity;
};

static char *project_strdup(const char *text) {
  if (!text) text = "";
  size_t len = strlen(text);
  if (len == SIZE_MAX) return NULL;
  char *copy = (char *)malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

static void set_error(char **error, const char *message) {
  if (error && !*error) *error = project_strdup(message ? message : "native Project file extraction failed");
}

static bool checked_grow(void **data, uint32_t *capacity, uint32_t needed, size_t item_size) {
  if (needed <= *capacity) return true;
  uint32_t next = *capacity ? *capacity : 16;
  while (next < needed) {
    if (next > UINT32_MAX / 2) { next = needed; break; }
    next *= 2;
  }
  if ((size_t)next > SIZE_MAX / item_size) return false;
  void *grown = realloc(*data, (size_t)next * item_size);
  if (!grown) return false;
  *data = grown;
  *capacity = next;
  return true;
}

static bool buffer_append(Buffer *buffer, const char *text, uint32_t length) {
  if (!length) return true;
  if (buffer->length > UINT32_MAX - length) return false;
  uint32_t needed = buffer->length + length;
  if (!checked_grow((void **)&buffer->data, &buffer->capacity, needed, 1)) return false;
  memcpy(buffer->data + buffer->length, text, length);
  buffer->length = needed;
  return true;
}

static bool buffer_append_byte(Buffer *buffer, char byte) {
  return buffer_append(buffer, &byte, 1);
}

static void buffer_free(Buffer *buffer) {
  if (!buffer) return;
  free(buffer->data);
  memset(buffer, 0, sizeof(*buffer));
}

static Slice absent_slice(void) {
  return (Slice) { .offset = ANVIL_PROJECT_NO_OFFSET, .length = 0 };
}

static bool arena_append(AnvilTSProjectFileResult *result, const char *text, uint32_t length, uint32_t limit, Slice *slice) {
  static const char suffix[] = "\xE2\x80\xA6[truncated]";
  uint32_t prefix = length;
  bool truncated = limit > 0 && length > limit;
  if (truncated) prefix = limit > 16 ? limit - 16 : 0;
  uint32_t suffix_len = truncated ? (uint32_t)(sizeof(suffix) - 1) : 0;
  if (prefix > UINT32_MAX - suffix_len) return false;
  uint32_t stored = prefix + suffix_len;
  if (stored == UINT32_MAX || result->arena_length > UINT32_MAX - stored - 1) return false;
  uint32_t needed = result->arena_length + stored + 1;
  if (!checked_grow((void **)&result->arena, &result->arena_capacity, needed, 1)) return false;
  slice->offset = result->arena_length;
  slice->length = stored;
  if (prefix) memcpy(result->arena + result->arena_length, text, prefix);
  if (suffix_len) memcpy(result->arena + result->arena_length + prefix, suffix, suffix_len);
  result->arena[result->arena_length + stored] = '\0';
  result->arena_length = needed;
  return true;
}

static const char *slice_text(const AnvilTSProjectFileResult *result, Slice slice) {
  return slice.offset == ANVIL_PROJECT_NO_OFFSET ? NULL : result->arena + slice.offset;
}

static bool arena_intern_label(AnvilTSProjectFileResult *result, const char *text, uint32_t length, Slice *slice) {
  for (uint32_t i = 0; i < result->interned_label_count; i++) {
    Slice existing = result->interned_labels[i];
    if (existing.length == length && (!length || memcmp(slice_text(result, existing), text, length) == 0)) {
      *slice = existing;
      return true;
    }
  }
  Slice added;
  if (!arena_append(result, text, length, 0, &added) ||
      !checked_grow((void **)&result->interned_labels, &result->interned_label_capacity,
        result->interned_label_count + 1, sizeof(*result->interned_labels))) return false;
  result->interned_labels[result->interned_label_count++] = added;
  *slice = added;
  return true;
}

static bool ascii_space(char byte) {
  return isspace((unsigned char)byte) != 0;
}

static bool collapse_whitespace(const char *text, uint32_t length, Buffer *out) {
  bool pending_space = false;
  bool seen = false;
  for (uint32_t i = 0; i < length; i++) {
    if (ascii_space(text[i])) {
      if (seen) pending_space = true;
      continue;
    }
    if (pending_space) {
      if (!buffer_append_byte(out, ' ')) return false;
      pending_space = false;
    }
    if (!buffer_append_byte(out, text[i])) return false;
    seen = true;
  }
  return true;
}

static bool capture_text(const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *capture, const char **text, uint32_t *length) {
  if (!snapshot || !capture || capture->start_byte > capture->end_byte || capture->end_byte > snapshot->byte_len) return false;
  *text = snapshot->bytes + capture->start_byte;
  *length = capture->end_byte - capture->start_byte;
  return true;
}

static bool starts_with(const char *text, uint32_t length, const char *prefix) {
  size_t prefix_len = strlen(prefix);
  return length >= prefix_len && memcmp(text, prefix, prefix_len) == 0;
}

static bool capture_definition_kind(const AnvilTSProjectCapture *capture, const char **kind, uint32_t *kind_len) {
  static const char prefix[] = "definition.";
  if (!capture || capture->name_len <= sizeof(prefix) - 1 || memcmp(capture->name, prefix, sizeof(prefix) - 1) != 0) return false;
  *kind = capture->name + sizeof(prefix) - 1;
  *kind_len = capture->name_len - (uint32_t)(sizeof(prefix) - 1);
  return true;
}

static bool usage_capture(const AnvilTSProjectCapture *capture) {
  if (!capture || !capture->name) return false;
  return (capture->name_len == 9 && memcmp(capture->name, "reference", 9) == 0) ||
    (capture->name_len == 5 && memcmp(capture->name, "usage", 5) == 0) ||
    (capture->name_len > 6 && memcmp(capture->name, "usage.", 6) == 0) ||
    (capture->name_len > 11 && memcmp(capture->name, "definition.", 11) == 0);
}

static AnvilTSProjectRange range_from_capture(const AnvilTSProjectCapture *capture) {
  return (AnvilTSProjectRange) {
    .start_byte = capture->start_byte,
    .end_byte = capture->end_byte,
    .start_point = capture->start_point,
    .end_point = capture->end_point,
  };
}

static uint32_t hash_u32(uint32_t value) {
  value ^= value >> 16;
  value *= UINT32_C(0x7feb352d);
  value ^= value >> 15;
  value *= UINT32_C(0x846ca68b);
  return value ^ (value >> 16);
}

static Group *group_for_capture(Group **groups, uint32_t *count, uint32_t *capacity, GroupSlot *slots, uint32_t slot_count, uint32_t match_id) {
  uint32_t slot = hash_u32(match_id) & (slot_count - 1);
  while (slots[slot].group_plus_one) {
    if (slots[slot].match_id == match_id) return &(*groups)[slots[slot].group_plus_one - 1];
    slot = (slot + 1) & (slot_count - 1);
  }
  if (!checked_grow((void **)groups, capacity, *count + 1, sizeof(**groups))) return NULL;
  Group *group = &(*groups)[(*count)++];
  memset(group, 0, sizeof(*group));
  group->match_id = match_id;
  group->item = ANVIL_PROJECT_NO_OFFSET;
  group->name = ANVIL_PROJECT_NO_OFFSET;
  slots[slot].match_id = match_id;
  slots[slot].group_plus_one = *count;
  return group;
}

static bool group_add_signature(Group *group, uint32_t capture_index) {
  if (!checked_grow((void **)&group->signatures, &group->signature_capacity, group->signature_count + 1, sizeof(uint32_t))) return false;
  group->signatures[group->signature_count++] = capture_index;
  return true;
}

static int signature_compare(const AnvilTSProjectCapture *captures, uint32_t left, uint32_t right) {
  const AnvilTSProjectCapture *a = &captures[left];
  const AnvilTSProjectCapture *b = &captures[right];
  if (a->start_byte != b->start_byte) return a->start_byte < b->start_byte ? -1 : 1;
  if (a->end_byte != b->end_byte) return a->end_byte < b->end_byte ? -1 : 1;
  uint32_t common = a->name_len < b->name_len ? a->name_len : b->name_len;
  int cmp = memcmp(a->name, b->name, common);
  if (cmp) return cmp;
  return a->name_len < b->name_len ? -1 : a->name_len > b->name_len;
}

static void sort_signatures(Group *group, const AnvilTSProjectCapture *captures) {
  for (uint32_t i = 1; i < group->signature_count; i++) {
    uint32_t value = group->signatures[i];
    uint32_t j = i;
    while (j > 0 && signature_compare(captures, value, group->signatures[j - 1]) < 0) {
      group->signatures[j] = group->signatures[j - 1];
      j--;
    }
    group->signatures[j] = value;
  }
}

static bool append_capture_text(Buffer *buffer, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *capture, bool separator) {
  const char *text;
  uint32_t length;
  if (!capture_text(snapshot, capture, &text, &length)) return false;
  if (separator && buffer->length && !buffer_append_byte(buffer, ' ')) return false;
  return buffer_append(buffer, text, length);
}

static bool build_signature(Buffer *out, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *captures, Group *group, const char *name, uint32_t name_len) {
  if (!group->signature_count) return true;
  sort_signatures(group, captures);
  Buffer raw = {0};
  uint32_t params = 0, returns = 0, full = 0;
  for (uint32_t i = 0; i < group->signature_count; i++) {
    const AnvilTSProjectCapture *capture = &captures[group->signatures[i]];
    if (capture->name_len == 16 && memcmp(capture->name, "signature.params", 16) == 0) params++;
    else if (capture->name_len == 16 && memcmp(capture->name, "signature.return", 16) == 0) returns++;
    else full++;
  }
  if (params) {
    uint32_t appended = 0;
    for (uint32_t i = 0; i < group->signature_count; i++) {
      const AnvilTSProjectCapture *capture = &captures[group->signatures[i]];
      if (capture->name_len == 16 && memcmp(capture->name, "signature.params", 16) == 0) {
        if (!append_capture_text(&raw, snapshot, capture, appended++ > 0)) goto fail;
      }
    }
    if (returns) {
      if (!buffer_append(&raw, " -> ", 4)) goto fail;
      uint32_t appended_returns = 0;
      for (uint32_t i = 0; i < group->signature_count; i++) {
        const AnvilTSProjectCapture *capture = &captures[group->signatures[i]];
        if (capture->name_len == 16 && memcmp(capture->name, "signature.return", 16) == 0) {
          if (!append_capture_text(&raw, snapshot, capture, appended_returns++ > 0)) goto fail;
        }
      }
    }
  } else if (full) {
    uint32_t appended = 0;
    for (uint32_t i = 0; i < group->signature_count; i++) {
      const AnvilTSProjectCapture *capture = &captures[group->signatures[i]];
      if (capture->name_len == 16 && (memcmp(capture->name, "signature.params", 16) == 0 || memcmp(capture->name, "signature.return", 16) == 0)) continue;
      if (!append_capture_text(&raw, snapshot, capture, appended++ > 0)) goto fail;
    }
    for (uint32_t i = 0; i < raw.length; i++) {
      if (raw.data[i] == '{') { raw.length = i; break; }
    }
    uint32_t start = 0;
    while (start < raw.length && ascii_space(raw.data[start])) start++;
    if (raw.length - start >= 4 && memcmp(raw.data + start, "proc", 4) == 0) {
      start += 4;
      while (start < raw.length && ascii_space(raw.data[start])) start++;
      memmove(raw.data, raw.data + start, raw.length - start);
      raw.length -= start;
    }
  }
  if (!collapse_whitespace(raw.data, raw.length, out)) goto fail;
  if (name_len && out->length >= name_len && memcmp(out->data, name, name_len) == 0) {
    uint32_t start = name_len;
    while (start < out->length && ascii_space(out->data[start])) start++;
    memmove(out->data, out->data + start, out->length - start);
    out->length -= start;
  }
  buffer_free(&raw);
  return true;
fail:
  buffer_free(&raw);
  return false;
}

static bool build_declaration(Buffer *out, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *item, const AnvilTSProjectCapture *name, uint32_t *span_start, uint32_t *span_end, bool *has_span) {
  const char *text;
  uint32_t length;
  if (!capture_text(snapshot, item, &text, &length)) return false;
  for (uint32_t i = 0; i < length; i++) {
    if (text[i] == '{') { length = i; break; }
  }
  if (!length || name->start_byte < item->start_byte || name->end_byte < name->start_byte) return true;
  uint32_t name_start = name->start_byte - item->start_byte;
  uint32_t name_end = name->end_byte - item->start_byte;
  bool pending_space = false, seen = false;
  for (uint32_t i = 0; i < length; i++) {
    if (ascii_space(text[i])) {
      if (seen) pending_space = true;
      continue;
    }
    if (pending_space) {
      if (!buffer_append_byte(out, ' ')) return false;
      pending_space = false;
    }
    if (!buffer_append_byte(out, text[i])) return false;
    seen = true;
    if (i >= name_start && i < name_end) {
      uint32_t position = out->length;
      if (!*has_span) { *span_start = position; *has_span = true; }
      *span_end = position;
    }
  }
  return true;
}

static int symbol_compare(const AnvilTSProjectFileResult *result, const Symbol *a, const Symbol *b) {
  if (a->range.start_byte != b->range.start_byte) return a->range.start_byte < b->range.start_byte ? -1 : 1;
  if (a->range.end_byte != b->range.end_byte) return a->range.end_byte > b->range.end_byte ? -1 : 1;
  uint32_t common = a->name.length < b->name.length ? a->name.length : b->name.length;
  int compared = common ? memcmp(slice_text(result, a->name), slice_text(result, b->name), common) : 0;
  if (compared) return compared;
  return a->name.length < b->name.length ? -1 : a->name.length > b->name.length;
}

static bool sort_symbols(AnvilTSProjectFileResult *result) {
  size_t count = result->symbol_count;
  if (count < 2) return true;
  Symbol *temporary = (Symbol *)malloc(count * sizeof(*temporary));
  if (!temporary) return false;
  Symbol *source = result->symbols;
  Symbol *destination = temporary;
  for (size_t width = 1; width < count; width = width > count / 2 ? count : width * 2) {
    for (size_t left = 0; left < count; left += width > (count - left) / 2 ? count - left : width * 2) {
      size_t middle = left + (width < count - left ? width : count - left);
      size_t right = middle + (width < count - middle ? width : count - middle);
      size_t a = left, b = middle, out = left;
      while (a < middle && b < right) {
        if (symbol_compare(result, &source[a], &source[b]) <= 0) destination[out++] = source[a++];
        else destination[out++] = source[b++];
      }
      while (a < middle) destination[out++] = source[a++];
      while (b < right) destination[out++] = source[b++];
    }
    Symbol *swap = source;
    source = destination;
    destination = swap;
  }
  if (source != result->symbols) memcpy(result->symbols, source, count * sizeof(*source));
  free(temporary);
  return true;
}

static bool contains_symbol(const Symbol *parent, const Symbol *child) {
  return parent != child && parent->range.start_byte <= child->range.start_byte && parent->range.end_byte >= child->range.end_byte &&
    (parent->range.start_byte != child->range.start_byte || parent->range.end_byte != child->range.end_byte);
}

static bool symbol_add_child(Symbol *symbol, uint32_t child) {
  if (!checked_grow((void **)&symbol->children, &symbol->child_capacity, symbol->child_count + 1, sizeof(uint32_t))) return false;
  symbol->children[symbol->child_count++] = child;
  return true;
}

static bool build_symbols(AnvilTSProjectFileResult *result, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *captures, uint32_t capture_count, char **error) {
  if (!capture_count) return true;
  if (capture_count > UINT32_MAX / 4) { set_error(error, "native Project symbol capture table is too large"); return false; }
  uint32_t target_slots = capture_count * 2;
  uint32_t slot_count = 16;
  while (slot_count < target_slots && slot_count <= UINT32_MAX / 2) slot_count *= 2;
  GroupSlot *slots = (GroupSlot *)calloc(slot_count, sizeof(*slots));
  Group *groups = NULL;
  uint32_t group_count = 0, group_capacity = 0;
  if (!slots) { set_error(error, "out of memory grouping native Project symbols"); return false; }

  for (uint32_t i = 0; i < capture_count; i++) {
    const AnvilTSProjectCapture *capture = &captures[i];
    Group *group = group_for_capture(&groups, &group_count, &group_capacity, slots, slot_count, capture->match_id);
    if (!group) goto oom;
    if (capture->name_len > 8 && memcmp(capture->name, "outline.", 8) == 0) {
      if (group->item == ANVIL_PROJECT_NO_OFFSET || capture->end_byte - capture->start_byte > captures[group->item].end_byte - captures[group->item].start_byte) {
        group->item = i;
        group->kind_source = (Slice) { .offset = i, .length = capture->name_len - 8 };
      }
    } else if (capture->name_len == 4 && memcmp(capture->name, "name", 4) == 0) {
      if (group->name == ANVIL_PROJECT_NO_OFFSET || capture->end_byte - capture->start_byte < captures[group->name].end_byte - captures[group->name].start_byte) group->name = i;
    } else if (capture->name_len >= 9 && memcmp(capture->name, "signature", 9) == 0) {
      if (!group_add_signature(group, i)) goto oom;
    }
  }

  for (uint32_t i = 0; i < group_count; i++) {
    Group *group = &groups[i];
    if (group->item == ANVIL_PROJECT_NO_OFFSET || group->name == ANVIL_PROJECT_NO_OFFSET) continue;
    const AnvilTSProjectCapture *item = &captures[group->item];
    const AnvilTSProjectCapture *name_capture = &captures[group->name];
    const char *raw_name;
    uint32_t raw_name_len;
    if (!capture_text(snapshot, name_capture, &raw_name, &raw_name_len)) continue;
    Buffer name = {0};
    if (!collapse_whitespace(raw_name, raw_name_len, &name)) { buffer_free(&name); goto oom; }
    if (!name.length) { buffer_free(&name); continue; }
    if (!checked_grow((void **)&result->symbols, &result->symbol_capacity, result->symbol_count + 1, sizeof(*result->symbols))) { buffer_free(&name); goto oom; }
    Symbol *symbol = &result->symbols[result->symbol_count++];
    memset(symbol, 0, sizeof(*symbol));
    symbol->signature = absent_slice();
    symbol->declaration = absent_slice();
    symbol->parent = ANVIL_PROJECT_NO_OFFSET;
    symbol->range = range_from_capture(item);
    symbol->name_range = range_from_capture(name_capture);
    if (!arena_append(result, name.data, name.length, 0, &symbol->name) ||
        !arena_intern_label(result, captures[group->item].name + 8, group->kind_source.length, &symbol->kind)) {
      buffer_free(&name); goto oom;
    }
    Buffer signature = {0};
    if (!build_signature(&signature, snapshot, captures, group, name.data, name.length)) { buffer_free(&name); buffer_free(&signature); goto oom; }
    if (signature.length && !arena_append(result, signature.data, signature.length, 1024, &symbol->signature)) { buffer_free(&name); buffer_free(&signature); goto oom; }
    Buffer declaration = {0};
    if (!build_declaration(&declaration, snapshot, item, name_capture, &symbol->declaration_name_start, &symbol->declaration_name_end, &symbol->has_declaration_name_span)) {
      buffer_free(&name); buffer_free(&signature); buffer_free(&declaration); goto oom;
    }
    if (declaration.length && !arena_append(result, declaration.data, declaration.length, 1024, &symbol->declaration)) {
      buffer_free(&name); buffer_free(&signature); buffer_free(&declaration); goto oom;
    }
    buffer_free(&name);
    buffer_free(&signature);
    buffer_free(&declaration);
  }

  if (!sort_symbols(result)) goto oom;
  Symbol **stack = result->symbol_count ? (Symbol **)malloc(sizeof(*stack) * result->symbol_count) : NULL;
  if (result->symbol_count && !stack) goto oom;
  uint32_t stack_count = 0;
  for (uint32_t i = 0; i < result->symbol_count; i++) {
    Symbol *symbol = &result->symbols[i];
    while (stack_count && !contains_symbol(stack[stack_count - 1], symbol)) stack_count--;
    if (stack_count) {
      Symbol *parent = stack[stack_count - 1];
      uint32_t parent_index = (uint32_t)(parent - result->symbols);
      symbol->parent = parent_index + 1;
      symbol->depth = parent->depth + 1;
      if (!symbol_add_child(parent, i + 1)) { free(stack); goto oom; }
    }
    stack[stack_count++] = symbol;
  }
  free(stack);
  for (uint32_t i = 0; i < group_count; i++) free(groups[i].signatures);
  free(groups);
  free(slots);
  return true;
oom:
  set_error(error, "out of memory constructing native Project symbols");
  for (uint32_t i = 0; i < group_count; i++) free(groups[i].signatures);
  free(groups);
  free(slots);
  return false;
}

static uint64_t usage_hash(const char *name, uint32_t name_len, uint32_t start, uint32_t end) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (uint32_t i = 0; i < name_len; i++) { hash ^= (unsigned char)name[i]; hash *= UINT64_C(1099511628211); }
  hash ^= start; hash *= UINT64_C(1099511628211);
  hash ^= end; hash *= UINT64_C(1099511628211);
  return hash ? hash : 1;
}

static int usage_compare(const void *left, const void *right) {
  const Usage *a = (const Usage *)left;
  const Usage *b = (const Usage *)right;
  if (a->range.start_byte != b->range.start_byte) return a->range.start_byte < b->range.start_byte ? -1 : 1;
  if (a->range.end_byte != b->range.end_byte) return a->range.end_byte < b->range.end_byte ? -1 : 1;
  if (a->name.offset != b->name.offset) return a->name.offset < b->name.offset ? -1 : 1;
  return a->capture.offset < b->capture.offset ? -1 : a->capture.offset > b->capture.offset;
}

static bool build_usage_record(AnvilTSProjectFileResult *result, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *capture, Usage *usage) {
  const char *name;
  uint32_t name_len;
  if (!capture_text(snapshot, capture, &name, &name_len) || !name_len) return false;
  memset(usage, 0, sizeof(*usage));
  usage->range = range_from_capture(capture);
  usage->is_declaration = starts_with(capture->name, capture->name_len, "definition.");
  const char *kind = "usage";
  uint32_t kind_len = 5;
  capture_definition_kind(capture, &kind, &kind_len);
  uint32_t row = capture->start_point.row;
  if (row >= snapshot->line_count) return false;
  uint32_t line_start = snapshot->line_starts[row];
  uint32_t line_len = snapshot->line_lengths[row];
  if (line_len && snapshot->bytes[line_start + line_len - 1] == '\n') line_len--;
  return arena_append(result, name, name_len, 0, &usage->name) &&
    arena_intern_label(result, capture->name, capture->name_len, &usage->capture) &&
    arena_intern_label(result, kind, kind_len, &usage->kind) &&
    arena_append(result, snapshot->bytes + line_start, line_len, 512, &usage->line_text);
}

static bool usage_same(const AnvilTSProjectFileResult *result, const Usage *usage, const char *name, uint32_t name_len, uint32_t start, uint32_t end) {
  return usage->range.start_byte == start && usage->range.end_byte == end && usage->name.length == name_len &&
    memcmp(slice_text(result, usage->name), name, name_len) == 0;
}

static bool build_usages(AnvilTSProjectFileResult *result, const AnvilTSSnapshot *snapshot, const AnvilTSProjectCapture *captures, uint32_t capture_count, char **error) {
  if (!capture_count) return true;
  if (capture_count > UINT32_MAX / 4) { set_error(error, "native Project usage capture table is too large"); return false; }
  uint32_t target_slots = capture_count * 2;
  uint32_t slot_count = 16;
  while (slot_count < target_slots && slot_count <= UINT32_MAX / 2) slot_count *= 2;
  UsageSlot *slots = (UsageSlot *)calloc(slot_count, sizeof(*slots));
  if (!slots) { set_error(error, "out of memory deduplicating native Project usages"); return false; }
  for (uint32_t i = 0; i < capture_count; i++) {
    const AnvilTSProjectCapture *capture = &captures[i];
    if (!usage_capture(capture)) continue;
    const char *name;
    uint32_t name_len;
    if (!capture_text(snapshot, capture, &name, &name_len) || !name_len) continue;
    uint64_t hash = usage_hash(name, name_len, capture->start_byte, capture->end_byte);
    uint32_t slot = (uint32_t)hash & (slot_count - 1);
    while (slots[slot].usage_plus_one) {
      Usage *existing = &result->usages[slots[slot].usage_plus_one - 1];
      if (slots[slot].hash == hash && usage_same(result, existing, name, name_len, capture->start_byte, capture->end_byte)) {
        bool declaration = starts_with(capture->name, capture->name_len, "definition.");
        if (declaration && !existing->is_declaration) {
          Usage replacement;
          if (!build_usage_record(result, snapshot, capture, &replacement)) goto oom;
          *existing = replacement;
        }
        goto next_capture;
      }
      slot = (slot + 1) & (slot_count - 1);
    }
    if (!checked_grow((void **)&result->usages, &result->usage_capacity, result->usage_count + 1, sizeof(*result->usages))) goto oom;
    if (!build_usage_record(result, snapshot, capture, &result->usages[result->usage_count])) goto oom;
    slots[slot].hash = hash;
    slots[slot].usage_plus_one = ++result->usage_count;
next_capture:;
  }
  qsort(result->usages, result->usage_count, sizeof(*result->usages), usage_compare);
  free(slots);
  return true;
oom:
  free(slots);
  set_error(error, "out of memory constructing native Project usages");
  return false;
}

AnvilTSProjectFileResult *anvil_ts_project_file_build(
  const AnvilTSSnapshot *snapshot,
  const char *path,
  const char *relpath,
  const char *language_id,
  const AnvilTSProjectCapture *outline,
  uint32_t outline_count,
  const AnvilTSProjectCapture *usages,
  uint32_t usage_count,
  char **error
) {
  if (error) *error = NULL;
  if (!snapshot || (outline_count && !outline) || (usage_count && !usages)) {
    set_error(error, "invalid native Project file extraction request");
    return NULL;
  }
  AnvilTSProjectFileResult *result = (AnvilTSProjectFileResult *)calloc(1, sizeof(*result));
  if (!result) { set_error(error, "out of memory allocating native Project file result"); return NULL; }
  SDL_SetAtomicInt(&result->refcount, 1);
  result->path = project_strdup(path);
  result->relpath = project_strdup(relpath ? relpath : path);
  result->language_id = project_strdup(language_id);
  if (!result->path || !result->relpath || !result->language_id ||
      !build_symbols(result, snapshot, outline, outline_count, error) ||
      !build_usages(result, snapshot, usages, usage_count, error)) {
    anvil_ts_project_file_free(result);
    return NULL;
  }
  return result;
}

void anvil_ts_project_file_retain(AnvilTSProjectFileResult *result) {
  if (result) SDL_AtomicIncRef(&result->refcount);
}

void anvil_ts_project_file_free(AnvilTSProjectFileResult *result) {
  if (!result || !SDL_AtomicDecRef(&result->refcount)) return;
  for (uint32_t i = 0; i < result->symbol_count; i++) free(result->symbols[i].children);
  free(result->symbols);
  free(result->usages);
  free(result->interned_labels);
  free(result->arena);
  free(result->path);
  free(result->relpath);
  free(result->language_id);
  free(result);
}

const char *anvil_ts_project_file_path(const AnvilTSProjectFileResult *result) { return result ? result->path : NULL; }
const char *anvil_ts_project_file_relpath(const AnvilTSProjectFileResult *result) { return result ? result->relpath : NULL; }
const char *anvil_ts_project_file_language(const AnvilTSProjectFileResult *result) { return result ? result->language_id : NULL; }
uint32_t anvil_ts_project_file_symbol_count(const AnvilTSProjectFileResult *result) { return result ? result->symbol_count : 0; }
uint32_t anvil_ts_project_file_usage_count(const AnvilTSProjectFileResult *result) { return result ? result->usage_count : 0; }

bool anvil_ts_project_file_symbol_at(const AnvilTSProjectFileResult *result, uint32_t index, AnvilTSProjectSymbolView *view) {
  if (!result || !view || index >= result->symbol_count) return false;
  const Symbol *symbol = &result->symbols[index];
  memset(view, 0, sizeof(*view));
  view->name = slice_text(result, symbol->name); view->name_len = symbol->name.length;
  view->kind = slice_text(result, symbol->kind); view->kind_len = symbol->kind.length;
  view->signature = slice_text(result, symbol->signature); view->signature_len = symbol->signature.length;
  view->declaration = slice_text(result, symbol->declaration); view->declaration_len = symbol->declaration.length;
  view->declaration_name_start = symbol->declaration_name_start;
  view->declaration_name_end = symbol->declaration_name_end;
  view->has_declaration_name_span = symbol->has_declaration_name_span;
  view->range = symbol->range; view->name_range = symbol->name_range;
  view->index = index + 1; view->parent = symbol->parent; view->depth = symbol->depth;
  view->children = symbol->children; view->child_count = symbol->child_count;
  return true;
}

bool anvil_ts_project_file_usage_at(const AnvilTSProjectFileResult *result, uint32_t index, AnvilTSProjectUsageView *view) {
  if (!result || !view || index >= result->usage_count) return false;
  const Usage *usage = &result->usages[index];
  memset(view, 0, sizeof(*view));
  view->name = slice_text(result, usage->name); view->name_len = usage->name.length;
  view->capture = slice_text(result, usage->capture); view->capture_len = usage->capture.length;
  view->kind = slice_text(result, usage->kind); view->kind_len = usage->kind.length;
  view->line_text = slice_text(result, usage->line_text); view->line_text_len = usage->line_text.length;
  view->is_declaration = usage->is_declaration; view->range = usage->range;
  return true;
}
