/*
 * Live Preview styles for the Companion's first test (docs/machines.md, Companion step 1).
 * It finds headings, bold text and wikilinks with the desktop's shared Markdown modules,
 * and reports them in UTF-16 units. This quick form is thrown away after the test.
 */
#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <tree_sitter/api.h>

#include "markdown_extensions.h"
#include "markdown_parser.h"

/* Kinds 1 to 6 are heading levels. A marker's owner is the index of its element. */
enum { KIND_BOLD = 7, KIND_WIKILINK = 8, KIND_MARKER = 9 };

typedef struct Spans {
  int32_t *items; /* kind, start, end, owner */
  size_t count;
  size_t capacity;
  bool failed;
} Spans;

typedef struct Exclusions {
  AnvilMarkdownExclusion *items;
  size_t count;
  size_t capacity;
  bool failed;
} Exclusions;

typedef struct LinkScan {
  Spans *spans;
  int element;
  uint32_t match_id;
  uint32_t target_start;
} LinkScan;

static int push_span(Spans *spans, int kind, uint32_t start, uint32_t end, int owner) {
  if (spans->failed || end <= start) return -1;
  if (spans->count == spans->capacity) {
    size_t capacity = spans->capacity ? spans->capacity * 2 : 64;
    int32_t *items = realloc(spans->items, capacity * 4 * sizeof(int32_t));
    if (!items) { spans->failed = true; return -1; }
    spans->items = items;
    spans->capacity = capacity;
  }
  int32_t *item = spans->items + spans->count * 4;
  item[0] = kind;
  item[1] = (int32_t) start;
  item[2] = (int32_t) end;
  item[3] = owner;
  return (int) spans->count++;
}

static void push_exclusion(Exclusions *exclusions, TSNode node) {
  if (exclusions->failed) return;
  if (exclusions->count == exclusions->capacity) {
    size_t capacity = exclusions->capacity ? exclusions->capacity * 2 : 16;
    AnvilMarkdownExclusion *items = realloc(exclusions->items, capacity * sizeof(*items));
    if (!items) { exclusions->failed = true; return; }
    exclusions->items = items;
    exclusions->capacity = capacity;
  }
  exclusions->items[exclusions->count++] = (AnvilMarkdownExclusion) {
    ts_node_start_byte(node), ts_node_end_byte(node),
  };
}

static bool is_type(TSNode node, const char *type) {
  return strcmp(ts_node_type(node), type) == 0;
}

/* `# Title`: the element is the line without its line break. The marker includes the spaces after `#`. */
static void add_heading(TSNode heading, const char *source, Spans *spans) {
  uint32_t count = ts_node_child_count(heading);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_child(heading, i);
    const char *type = ts_node_type(child);
    if (strncmp(type, "atx_h", 5) != 0 || type[5] < '1' || type[5] > '6') continue;
    uint32_t start = ts_node_start_byte(heading), end = ts_node_end_byte(heading);
    while (end > start && (source[end - 1] == '\n' || source[end - 1] == '\r')) end--;
    int element = push_span(spans, type[5] - '0', start, end, -1);
    uint32_t marker_end = ts_node_end_byte(child);
    while (marker_end < end && source[marker_end] == ' ') marker_end++;
    push_span(spans, KIND_MARKER, ts_node_start_byte(child), marker_end, element);
    return;
  }
}

static void walk_blocks(TSNode node, const char *source, Spans *spans, Exclusions *exclusions) {
  if (is_type(node, "atx_heading")) return add_heading(node, source, spans);
  if (is_type(node, "fenced_code_block") || is_type(node, "indented_code_block")) {
    return push_exclusion(exclusions, node);
  }
  uint32_t count = ts_node_named_child_count(node);
  for (uint32_t i = 0; i < count; i++) walk_blocks(ts_node_named_child(node, i), source, spans, exclusions);
}

static void walk_inline(TSNode node, Spans *spans, Exclusions *exclusions) {
  if (is_type(node, "code_span")) return push_exclusion(exclusions, node);
  int element = -1;
  if (is_type(node, "strong_emphasis")) {
    element = push_span(spans, KIND_BOLD, ts_node_start_byte(node), ts_node_end_byte(node), -1);
  }
  uint32_t count = ts_node_child_count(node);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_child(node, i);
    if (element >= 0 && is_type(child, "emphasis_delimiter")) {
      push_span(spans, KIND_MARKER, ts_node_start_byte(child), ts_node_end_byte(child), element);
    } else {
      walk_inline(child, spans, exclusions);
    }
  }
}

/* `[[target|alias]]` shows only the alias, so `target|` is a marker too. */
static bool add_link_capture(const AnvilMarkdownExtensionCapture *capture, void *payload) {
  LinkScan *scan = payload;
  if (strcmp(capture->name, "span.wiki_link") == 0) {
    scan->element = push_span(scan->spans, KIND_WIKILINK, capture->start_byte, capture->end_byte, -1);
    scan->match_id = capture->match_id;
  } else if (scan->element >= 0 && capture->match_id == scan->match_id) {
    if (strcmp(capture->name, "marker.wiki_open") == 0 || strcmp(capture->name, "marker.wiki_close") == 0) {
      push_span(scan->spans, KIND_MARKER, capture->start_byte, capture->end_byte, scan->element);
    } else if (strcmp(capture->name, "content.target") == 0) {
      scan->target_start = capture->start_byte;
    } else if (strcmp(capture->name, "content.alias") == 0) {
      push_span(scan->spans, KIND_MARKER, scan->target_start, capture->start_byte, scan->element);
    }
  }
  return !scan->spans->failed;
}

static int compare_exclusions(const void *a, const void *b) {
  uint32_t left = ((const AnvilMarkdownExclusion *) a)->start_byte;
  uint32_t right = ((const AnvilMarkdownExclusion *) b)->start_byte;
  return left < right ? -1 : left > right;
}

/* UTF-16 text to UTF-8. `units_at[byte]` gives the UTF-16 offset of each UTF-8 offset. */
static char *to_utf8(const jchar *text, jsize length, uint32_t *out_length, uint32_t **out_units_at) {
  char *bytes = malloc((size_t) length * 3 + 1);
  uint32_t *units_at = malloc(((size_t) length * 3 + 1) * sizeof(uint32_t));
  if (!bytes || !units_at) { free(bytes); free(units_at); return NULL; }
  uint32_t n = 0;
  for (jsize i = 0; i < length; i++) {
    uint32_t start = (uint32_t) i, code = text[i];
    if (code >= 0xd800 && code < 0xdc00 && i + 1 < length && text[i + 1] >= 0xdc00 && text[i + 1] < 0xe000) {
      code = 0x10000 + ((code - 0xd800) << 10) + (text[i + 1] - 0xdc00);
      i++;
    } else if (code >= 0xd800 && code < 0xe000) {
      code = 0xfffd;
    }
    uint32_t first = n;
    if (code < 0x80) {
      bytes[n++] = (char) code;
    } else if (code < 0x800) {
      bytes[n++] = (char) (0xc0 | code >> 6);
      bytes[n++] = (char) (0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes[n++] = (char) (0xe0 | code >> 12);
      bytes[n++] = (char) (0x80 | (code >> 6 & 0x3f));
      bytes[n++] = (char) (0x80 | (code & 0x3f));
    } else {
      bytes[n++] = (char) (0xf0 | code >> 18);
      bytes[n++] = (char) (0x80 | (code >> 12 & 0x3f));
      bytes[n++] = (char) (0x80 | (code >> 6 & 0x3f));
      bytes[n++] = (char) (0x80 | (code & 0x3f));
    }
    for (uint32_t b = first; b < n; b++) units_at[b] = start;
  }
  bytes[n] = '\0';
  units_at[n] = (uint32_t) length;
  *out_length = n;
  *out_units_at = units_at;
  return bytes;
}

JNIEXPORT jintArray JNICALL
Java_io_github_dcostap_anvil_MarkdownStyles_scan(JNIEnv *env, jclass cls, jstring text) {
  (void) cls;
  jsize length = (*env)->GetStringLength(env, text);
  const jchar *chars = (*env)->GetStringChars(env, text, NULL);
  if (!chars) return NULL;
  uint32_t byte_length = 0, *units_at = NULL;
  char *bytes = to_utf8(chars, length, &byte_length, &units_at);
  (*env)->ReleaseStringChars(env, text, chars);
  if (!bytes) return NULL;

  char *error = NULL;
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_take_text(bytes, byte_length, &error);
  AnvilMarkdownTree *tree = snapshot ? anvil_markdown_tree_parse(snapshot, 0, NULL, NULL, &error) : NULL;
  free(error);
  Spans spans = {0};
  Exclusions exclusions = {0};
  if (tree) {
    walk_blocks(ts_tree_root_node(anvil_markdown_tree_block_tree(tree)), snapshot->bytes, &spans, &exclusions);
    uint32_t inline_count = anvil_markdown_tree_inline_count(tree);
    for (uint32_t i = 0; i < inline_count; i++) {
      TSTree *inline_tree = anvil_markdown_tree_copy_inline_tree(tree, i);
      if (!inline_tree) continue;
      walk_inline(ts_tree_root_node(inline_tree), &spans, &exclusions);
      ts_tree_delete(inline_tree);
    }
    if (!exclusions.failed) {
      qsort(exclusions.items, exclusions.count, sizeof(*exclusions.items), compare_exclusions);
      LinkScan scan = { .spans = &spans, .element = -1 };
      anvil_markdown_extensions_scan(snapshot, exclusions.items, (uint32_t) exclusions.count,
        add_link_capture, &scan, NULL, NULL);
    }
    anvil_markdown_tree_free(tree);
  }
  if (snapshot) anvil_ts_snapshot_free(snapshot);
  free(exclusions.items);

  jintArray result = NULL;
  if (!spans.failed) {
    for (size_t i = 0; i < spans.count; i++) {
      spans.items[i * 4 + 1] = (int32_t) units_at[spans.items[i * 4 + 1]];
      spans.items[i * 4 + 2] = (int32_t) units_at[spans.items[i * 4 + 2]];
    }
    result = (*env)->NewIntArray(env, (jsize) (spans.count * 4));
    if (result) (*env)->SetIntArrayRegion(env, result, 0, (jsize) (spans.count * 4), spans.items);
  }
  free(spans.items);
  free(units_at);
  return result;
}
