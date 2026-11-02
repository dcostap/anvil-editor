/*
 * Live Preview styles of the Companion's note editor. It finds the Markdown elements with the desktop's shared
 * Markdown modules and reports them in UTF-16 units, for `MarkdownStyles.kt`.
 * A marker is syntax that hides while the caret is outside its element. Its owner is the index of its element.
 */
#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <tree_sitter/api.h>

#include "markdown_extensions.h"
#include "markdown_parser.h"

/* Kinds 1 to 6 are heading levels. Keep these in step with `MarkdownSpan`. */
enum {
  KIND_BOLD = 7, KIND_ITALIC, KIND_STRIKE, KIND_CODE, KIND_LINK, KIND_WIKILINK, KIND_HIGHLIGHT, KIND_TAG,
  KIND_CODE_BLOCK, KIND_QUOTE, KIND_LIST_MARKER, KIND_TASK_DONE, KIND_SYNTAX, KIND_TABLE, KIND_MARKER,
};

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

typedef struct Scan {
  const char *source;
  Spans spans;
  Exclusions exclusions;
} Scan;

typedef struct ExtensionScan {
  Spans *spans;
  int element;
  uint32_t match_id;
  uint32_t target_start;
} ExtensionScan;

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

static void push_exclusion(Exclusions *exclusions, uint32_t start, uint32_t end) {
  if (exclusions->failed) return;
  if (exclusions->count == exclusions->capacity) {
    size_t capacity = exclusions->capacity ? exclusions->capacity * 2 : 16;
    AnvilMarkdownExclusion *items = realloc(exclusions->items, capacity * sizeof(*items));
    if (!items) { exclusions->failed = true; return; }
    exclusions->items = items;
    exclusions->capacity = capacity;
  }
  exclusions->items[exclusions->count++] = (AnvilMarkdownExclusion) { start, end };
}

static bool is_type(TSNode node, const char *type) {
  return strcmp(ts_node_type(node), type) == 0;
}

static bool has_prefix(TSNode node, const char *prefix) {
  return strncmp(ts_node_type(node), prefix, strlen(prefix)) == 0;
}

/* A block node ends after its line break. Styles end before it, so they do not reach the next line. */
static uint32_t line_end(const char *source, uint32_t start, uint32_t end) {
  while (end > start && (source[end - 1] == '\n' || source[end - 1] == '\r')) end--;
  return end;
}

static int push_node(Scan *scan, int kind, TSNode node, int owner) {
  uint32_t start = ts_node_start_byte(node);
  return push_span(&scan->spans, kind, start, line_end(scan->source, start, ts_node_end_byte(node)), owner);
}

/* `# Title`: the element is the line. The marker includes the spaces after `#`. */
static void add_atx_heading(Scan *scan, TSNode heading) {
  uint32_t count = ts_node_child_count(heading);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_child(heading, i);
    const char *type = ts_node_type(child);
    if (strncmp(type, "atx_h", 5) != 0 || type[5] < '1' || type[5] > '6') continue;
    int element = push_node(scan, type[5] - '0', heading, -1);
    uint32_t end = line_end(scan->source, ts_node_start_byte(heading), ts_node_end_byte(heading));
    uint32_t marker_end = ts_node_end_byte(child);
    while (marker_end < end && scan->source[marker_end] == ' ') marker_end++;
    push_span(&scan->spans, KIND_MARKER, ts_node_start_byte(child), marker_end, element);
    return;
  }
}

/* `Title` above `===` or `---`. The underline stays visible, because a hidden line still takes its row. */
static void add_setext_heading(Scan *scan, TSNode heading) {
  uint32_t count = ts_node_child_count(heading);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_child(heading, i);
    if (is_type(child, "paragraph")) {
      TSNode underline = ts_node_next_sibling(child);
      int level = !ts_node_is_null(underline) && is_type(underline, "setext_h1_underline") ? 1 : 2;
      push_node(scan, level, child, -1);
    } else if (has_prefix(child, "setext_h")) {
      push_node(scan, KIND_SYNTAX, child, -1);
    }
  }
}

static void walk_blocks(Scan *scan, TSNode node) {
  if (is_type(node, "atx_heading")) return add_atx_heading(scan, node);
  if (is_type(node, "setext_heading")) return add_setext_heading(scan, node);
  if (is_type(node, "fenced_code_block") || is_type(node, "indented_code_block")) {
    push_exclusion(&scan->exclusions, ts_node_start_byte(node), ts_node_end_byte(node));
    push_node(scan, KIND_CODE_BLOCK, node, -1);
    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
      TSNode child = ts_node_child(node, i);
      if (is_type(child, "fenced_code_block_delimiter") || is_type(child, "info_string")) {
        push_node(scan, KIND_SYNTAX, child, -1);
      }
    }
    return;
  }
  if (is_type(node, "minus_metadata") || is_type(node, "plus_metadata")) {
    push_exclusion(&scan->exclusions, ts_node_start_byte(node), ts_node_end_byte(node));
    push_node(scan, KIND_SYNTAX, node, -1);
    return;
  }
  if (is_type(node, "html_block")) {
    push_exclusion(&scan->exclusions, ts_node_start_byte(node), ts_node_end_byte(node));
    return;
  }
  if (is_type(node, "thematic_break") || is_type(node, "block_quote_marker") ||
      is_type(node, "pipe_table_delimiter_row")) {
    push_node(scan, KIND_SYNTAX, node, -1);
    return;
  }
  /* A done task dims its text, the paragraph after its marker. */
  if (is_type(node, "task_list_marker_checked")) {
    TSNode text = ts_node_next_named_sibling(node);
    if (!ts_node_is_null(text) && is_type(text, "paragraph")) push_node(scan, KIND_TASK_DONE, text, -1);
  }
  if (has_prefix(node, "list_marker_") || is_type(node, "task_list_marker_unchecked") ||
      is_type(node, "task_list_marker_checked")) {
    push_node(scan, KIND_LIST_MARKER, node, -1);
    return;
  }
  if (is_type(node, "block_quote")) push_node(scan, KIND_QUOTE, node, -1);
  if (is_type(node, "pipe_table")) push_node(scan, KIND_TABLE, node, -1);
  uint32_t count = ts_node_child_count(node);
  for (uint32_t i = 0; i < count; i++) walk_blocks(scan, ts_node_child(node, i));
}

/* A link shows only its text. Each part outside the text child is a marker: `[`, `](url "title")`, or `![`. */
static void add_link(Scan *scan, TSNode node, const char *text_type) {
  uint32_t start = ts_node_start_byte(node), end = ts_node_end_byte(node);
  int element = push_span(&scan->spans, KIND_LINK, start, end, -1);
  uint32_t count = ts_node_named_child_count(node);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_named_child(node, i);
    if (!is_type(child, text_type)) continue;
    push_span(&scan->spans, KIND_MARKER, start, ts_node_start_byte(child), element);
    push_span(&scan->spans, KIND_MARKER, ts_node_end_byte(child), end, element);
    /* The destination and the title are not text, so they hold no tags. */
    push_exclusion(&scan->exclusions, ts_node_end_byte(child), end);
    return;
  }
}

/* `parent` is the element of the enclosing node and `parent_kind` its kind. `~~text~~` parses as a strikethrough
   inside a strikethrough, so a direct child of the same kind joins its parent. */
static void walk_inline(Scan *scan, TSNode node, int parent_kind, int parent) {
  if (is_type(node, "code_span")) {
    push_exclusion(&scan->exclusions, ts_node_start_byte(node), ts_node_end_byte(node));
    int element = push_node(scan, KIND_CODE, node, -1);
    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
      TSNode child = ts_node_child(node, i);
      if (is_type(child, "code_span_delimiter")) push_node(scan, KIND_MARKER, child, element);
    }
    return;
  }
  /* Reference links need their definitions, which the parser does not match. Text in brackets without a
     definition, such as the inside of `[[target]]`, is not a link. */
  if (is_type(node, "inline_link")) return add_link(scan, node, "link_text");
  if (is_type(node, "image")) return add_link(scan, node, "image_description");
  if (is_type(node, "uri_autolink") || is_type(node, "email_autolink")) {
    push_exclusion(&scan->exclusions, ts_node_start_byte(node), ts_node_end_byte(node));
    uint32_t start = ts_node_start_byte(node), end = ts_node_end_byte(node);
    int element = push_span(&scan->spans, KIND_LINK, start, end, -1);
    if (end - start >= 2 && scan->source[start] == '<') {
      push_span(&scan->spans, KIND_MARKER, start, start + 1, element);
      push_span(&scan->spans, KIND_MARKER, end - 1, end, element);
    }
    return;
  }
  int kind = is_type(node, "strong_emphasis") ? KIND_BOLD : is_type(node, "emphasis") ? KIND_ITALIC
    : is_type(node, "strikethrough") ? KIND_STRIKE : 0;
  int element = !kind ? -1 : kind == parent_kind ? parent : push_node(scan, kind, node, -1);
  uint32_t count = ts_node_child_count(node);
  for (uint32_t i = 0; i < count; i++) {
    TSNode child = ts_node_child(node, i);
    if (element >= 0 && is_type(child, "emphasis_delimiter")) {
      push_node(scan, KIND_MARKER, child, element);
    } else {
      walk_inline(scan, child, kind, element);
    }
  }
}

/* `[[target|alias]]` shows only the alias, so `target|` is a marker too. `==text==` hides its `==`. */
static bool add_extension(const AnvilMarkdownExtensionCapture *capture, void *payload) {
  ExtensionScan *scan = payload;
  const char *name = capture->name;
  if (strcmp(name, "span.wiki_link") == 0 || strcmp(name, "span.embed") == 0) {
    scan->element = push_span(scan->spans, KIND_WIKILINK, capture->start_byte, capture->end_byte, -1);
    scan->match_id = capture->match_id;
  } else if (strcmp(name, "span.highlight") == 0) {
    scan->element = push_span(scan->spans, KIND_HIGHLIGHT, capture->start_byte, capture->end_byte, -1);
    scan->match_id = capture->match_id;
  } else if (strcmp(name, "span.tag") == 0) {
    push_span(scan->spans, KIND_TAG, capture->start_byte, capture->end_byte, -1);
  } else if (scan->element >= 0 && capture->match_id == scan->match_id) {
    if (strcmp(name, "marker.wiki_open") == 0 || strcmp(name, "marker.wiki_close") == 0 ||
        strcmp(name, "marker.embed_open") == 0 || strcmp(name, "marker.embed_close") == 0 ||
        strcmp(name, "marker.highlight_open") == 0 || strcmp(name, "marker.highlight_close") == 0) {
      push_span(scan->spans, KIND_MARKER, capture->start_byte, capture->end_byte, scan->element);
    } else if (strcmp(name, "content.target") == 0) {
      scan->target_start = capture->start_byte;
    } else if (strcmp(name, "content.alias") == 0) {
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
  Scan scan = { .source = snapshot ? snapshot->bytes : NULL };
  if (tree) {
    walk_blocks(&scan, ts_tree_root_node(anvil_markdown_tree_block_tree(tree)));
    uint32_t inline_count = anvil_markdown_tree_inline_count(tree);
    for (uint32_t i = 0; i < inline_count; i++) {
      TSTree *inline_tree = anvil_markdown_tree_copy_inline_tree(tree, i);
      if (!inline_tree) continue;
      walk_inline(&scan, ts_tree_root_node(inline_tree), 0, -1);
      ts_tree_delete(inline_tree);
    }
    if (!scan.exclusions.failed) {
      qsort(scan.exclusions.items, scan.exclusions.count, sizeof(*scan.exclusions.items), compare_exclusions);
      ExtensionScan extensions = { .spans = &scan.spans, .element = -1 };
      anvil_markdown_extensions_scan(snapshot, scan.exclusions.items, (uint32_t) scan.exclusions.count,
        add_extension, &extensions, NULL, NULL);
    }
    anvil_markdown_tree_free(tree);
  }
  if (snapshot) anvil_ts_snapshot_free(snapshot);
  free(scan.exclusions.items);

  jintArray result = NULL;
  Spans *spans = &scan.spans;
  if (!spans->failed) {
    for (size_t i = 0; i < spans->count; i++) {
      spans->items[i * 4 + 1] = (int32_t) units_at[spans->items[i * 4 + 1]];
      spans->items[i * 4 + 2] = (int32_t) units_at[spans->items[i * 4 + 2]];
    }
    result = (*env)->NewIntArray(env, (jsize) (spans->count * 4));
    if (result) (*env)->SetIntArrayRegion(env, result, 0, (jsize) (spans->count * 4), spans->items);
  }
  free(spans->items);
  free(units_at);
  return result;
}
