#include "markdown_extensions.h"

#include <stdlib.h>
#include <string.h>

typedef struct ExtensionScan {
  const char *source;
  uint8_t *escaped;
  uint32_t length;
  const AnvilMarkdownExclusion *exclusions;
  uint32_t exclusion_count;
  uint32_t exclusion_cursor;
  AnvilMarkdownExtensionCaptureCallback capture_callback;
  void *capture_payload;
  AnvilMarkdownExtensionCancelCallback cancel_callback;
  void *cancel_payload;
  uint32_t wikilink_disabled_until;
  uint32_t highlight_disabled_until;
  uint32_t active_match_id;
  uint32_t next_match_id;
  bool comments_exhausted;
  /* Matching close brackets for the line part after an inline footnote's
     open bracket, indexed from bracket_start. */
  uint32_t *bracket_close;
  uint32_t bracket_capacity;
  uint32_t bracket_start;
  uint32_t bracket_end;
} ExtensionScan;

static bool escaped_at(const ExtensionScan *scan, uint32_t position) {
  return scan->escaped && position < scan->length && scan->escaped[position] != 0;
}

static bool cancelled(ExtensionScan *scan) {
  return scan->cancel_callback && scan->cancel_callback(scan->cancel_payload);
}

static bool excluded_at(ExtensionScan *scan, uint32_t position, uint32_t *end_byte) {
  while (scan->exclusion_cursor < scan->exclusion_count &&
    scan->exclusions[scan->exclusion_cursor].end_byte <= position) {
    scan->exclusion_cursor++;
  }
  if (scan->exclusion_cursor >= scan->exclusion_count) return false;
  const AnvilMarkdownExclusion *range = &scan->exclusions[scan->exclusion_cursor];
  if (range->start_byte > position || range->end_byte <= position) return false;
  if (end_byte) *end_byte = range->end_byte;
  return true;
}

static bool whitespace(char byte) {
  return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n';
}

static bool ascii_alnum(char byte) {
  return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
    (byte >= '0' && byte <= '9');
}

static bool tag_byte(char byte) {
  return ascii_alnum(byte) || byte == '_' || byte == '-' || byte == '/' ||
    (unsigned char)byte >= 0x80;
}

static bool tag_boundary_before(const ExtensionScan *scan, uint32_t position) {
  if (position == 0) return true;
  char previous = scan->source[position - 1];
  return !ascii_alnum(previous) && previous != '_';
}

static uint32_t find_delimiter(
  ExtensionScan *scan,
  uint32_t start,
  char first,
  char second,
  bool allow_newline,
  bool require_nonspace_before
) {
  uint32_t cursor = start;
  uint32_t saved_exclusion_cursor = scan->exclusion_cursor;
  while (cursor + 1 < scan->length) {
    if ((cursor & 0x3fff) == 0 && cancelled(scan)) break;
    if (!allow_newline && scan->source[cursor] == '\n') break;
    uint32_t excluded_end = 0;
    if (excluded_at(scan, cursor, &excluded_end)) {
      cursor = excluded_end;
      continue;
    }
    if (scan->source[cursor] == first && scan->source[cursor + 1] == second &&
      !escaped_at(scan, cursor) &&
      (!require_nonspace_before || (cursor > start && !whitespace(scan->source[cursor - 1])))) {
      scan->exclusion_cursor = saved_exclusion_cursor;
      return cursor;
    }
    cursor++;
  }
  scan->exclusion_cursor = saved_exclusion_cursor;
  return UINT32_MAX;
}

static uint32_t next_line_start(const ExtensionScan *scan, uint32_t position) {
  while (position < scan->length && scan->source[position] != '\n') position++;
  return position < scan->length ? position + 1 : scan->length;
}

/* A footnote label has no whitespace or brackets. */
static bool footnote_label_byte(char byte) {
  return !whitespace(byte) && byte != '[' && byte != ']';
}

/* A footnote definition starts its line after at most three spaces. */
static bool at_definition_indent(const ExtensionScan *scan, uint32_t position) {
  uint32_t spaces = 0;
  while (position > 0 && scan->source[position - 1] != '\n') {
    if (scan->source[position - 1] != ' ' || ++spaces > 3) return false;
    position--;
  }
  return true;
}

/* Finds the close bracket that matches the open bracket at `open` on its
   line. One pass matches every bracket from `open` to the line end, so a
   line of unclosed brackets stays linear. Returns 1 when found, 0 when the
   bracket has no match, and -1 when out of memory. */
static int bracket_close_at(ExtensionScan *scan, uint32_t open, uint32_t *close) {
  if (open < scan->bracket_start || open >= scan->bracket_end) {
    uint32_t end = open;
    while (end < scan->length && scan->source[end] != '\n') end++;
    uint32_t length = end - open;
    if (length * 2 > scan->bracket_capacity) {
      uint32_t *table = (uint32_t *)realloc(scan->bracket_close, sizeof(*table) * length * 2);
      if (!table) return -1;
      scan->bracket_close = table;
      scan->bracket_capacity = length * 2;
    }
    uint32_t *stack = scan->bracket_close + length;
    uint32_t depth = 0;
    for (uint32_t position = open; position < end; position++) {
      scan->bracket_close[position - open] = UINT32_MAX;
      if (escaped_at(scan, position)) continue;
      char byte = scan->source[position];
      if (byte == '[') stack[depth++] = position;
      else if (byte == ']' && depth > 0) scan->bracket_close[stack[--depth] - open] = position;
    }
    scan->bracket_start = open;
    scan->bracket_end = end;
  }
  *close = scan->bracket_close[open - scan->bracket_start];
  return *close != UINT32_MAX;
}

static bool emit(ExtensionScan *scan, const char *name, uint32_t start, uint32_t end) {
  if (end <= start) return true;
  AnvilMarkdownExtensionCapture capture = {
    .name = name,
    .start_byte = start,
    .end_byte = end,
    .match_id = scan->active_match_id,
  };
  return scan->capture_callback && scan->capture_callback(&capture, scan->capture_payload);
}

static uint32_t find_unescaped_pipe(ExtensionScan *scan, uint32_t start, uint32_t end) {
  for (uint32_t cursor = start; cursor < end; cursor++) {
    if ((cursor & 0x3fff) == 0 && cancelled(scan)) return UINT32_MAX;
    if (scan->source[cursor] == '|' && !escaped_at(scan, cursor)) return cursor;
  }
  return UINT32_MAX;
}

static bool emit_wikilink(
  ExtensionScan *scan,
  uint32_t start,
  uint32_t open_length,
  uint32_t close,
  uint32_t pipe,
  bool embed
) {
  uint32_t content_start = start + open_length;
  if (content_start >= close) return true;
  scan->active_match_id = scan->next_match_id++;
  const char *parent = embed ? "span.embed" : "span.wiki_link";
  if (!emit(scan, parent, start, close + 2) ||
      !emit(scan, embed ? "marker.embed_open" : "marker.wiki_open", start, content_start) ||
      !emit(scan, "content.target", content_start, pipe == UINT32_MAX ? close : pipe) ||
      (pipe != UINT32_MAX && !emit(scan, "content.alias", pipe + 1, close)) ||
      !emit(scan, embed ? "marker.embed_close" : "marker.wiki_close", close, close + 2)) {
    return false;
  }
  return true;
}

static bool scan_extensions(ExtensionScan *scan) {
  uint32_t cursor = 0;
  while (cursor + 1 < scan->length) {
    if ((cursor & 0x3fff) == 0 && cancelled(scan)) return false;
    uint32_t excluded_end = 0;
    if (excluded_at(scan, cursor, &excluded_end)) {
      cursor = excluded_end;
      continue;
    }
    if (escaped_at(scan, cursor)) {
      cursor++;
      continue;
    }

    if (!scan->comments_exhausted && scan->source[cursor] == '%' &&
        scan->source[cursor + 1] == '%') {
      uint32_t close = find_delimiter(scan, cursor + 2, '%', '%', true, false);
      if (close != UINT32_MAX) {
        if (close > cursor + 2) scan->active_match_id = scan->next_match_id++;
        if (close > cursor + 2 &&
            (!emit(scan, "span.comment", cursor, close + 2) ||
              !emit(scan, "marker.comment_open", cursor, cursor + 2) ||
              !emit(scan, "content.comment", cursor + 2, close) ||
              !emit(scan, "marker.comment_close", close, close + 2))) return false;
        cursor = close + 2;
        continue;
      }
      scan->comments_exhausted = true;
    }

    /* Pandoc footnotes: a [^label] reference, or a [^label]: text definition
       that fills the rest of its line. */
    if (scan->source[cursor] == '[' && scan->source[cursor + 1] == '^') {
      uint32_t label_end = cursor + 2;
      while (label_end < scan->length && footnote_label_byte(scan->source[label_end])) label_end++;
      if (label_end > cursor + 2 && label_end < scan->length && scan->source[label_end] == ']') {
        uint32_t end = label_end + 1;
        scan->active_match_id = scan->next_match_id++;
        if (end < scan->length && scan->source[end] == ':' && at_definition_indent(scan, cursor)) {
          uint32_t text_start = end + 1;
          while (text_start < scan->length &&
            (scan->source[text_start] == ' ' || scan->source[text_start] == '\t')) text_start++;
          uint32_t text_end = text_start;
          while (text_end < scan->length && scan->source[text_end] != '\n') text_end++;
          while (text_end > text_start && whitespace(scan->source[text_end - 1])) text_end--;
          if (!emit(scan, "span.footnote_definition", cursor, text_end) ||
              !emit(scan, "marker.footnote_definition_open", cursor, text_start) ||
              !emit(scan, "content.footnote_label", cursor + 2, label_end) ||
              !emit(scan, "content.footnote_text", text_start, text_end)) return false;
          /* The text still gets its inline extensions. */
          cursor = text_start;
          continue;
        }
        if (!emit(scan, "span.footnote_reference", cursor, end) ||
            !emit(scan, "marker.footnote_reference_open", cursor, cursor + 2) ||
            !emit(scan, "content.footnote_label", cursor + 2, label_end) ||
            !emit(scan, "marker.footnote_reference_close", label_end, end)) return false;
        cursor = end;
        continue;
      }
    }

    /* A Pandoc inline footnote: ^[text], with balanced brackets on one line. */
    if (scan->source[cursor] == '^' && scan->source[cursor + 1] == '[') {
      uint32_t close = 0;
      int found = bracket_close_at(scan, cursor + 1, &close);
      if (found < 0) return false;
      if (found) {
        scan->active_match_id = scan->next_match_id++;
        if (!emit(scan, "span.footnote_inline", cursor, close + 1) ||
            !emit(scan, "marker.footnote_inline_open", cursor, cursor + 2) ||
            !emit(scan, "content.footnote_text", cursor + 2, close) ||
            !emit(scan, "marker.footnote_inline_close", close, close + 1)) return false;
        cursor = close + 1;
        continue;
      }
    }

    if (scan->source[cursor] == '#' && cursor + 1 < scan->length &&
        tag_boundary_before(scan, cursor) && tag_byte(scan->source[cursor + 1]) &&
        scan->source[cursor + 1] != '-' && scan->source[cursor + 1] != '/') {
      uint32_t end = cursor + 1;
      bool has_non_digit = false;
      while (end < scan->length && tag_byte(scan->source[end])) {
        char byte = scan->source[end];
        if ((byte < '0' || byte > '9') && byte != '-' && byte != '/') has_non_digit = true;
        end++;
      }
      while (end > cursor + 1 && scan->source[end - 1] == '/') end--;
      if (has_non_digit && end > cursor + 1) {
        scan->active_match_id = scan->next_match_id++;
        if (!emit(scan, "span.tag", cursor, end) ||
            !emit(scan, "content.tag", cursor + 1, end)) return false;
        cursor = end;
        continue;
      }
    }

    if (cursor >= scan->wikilink_disabled_until && cursor + 2 < scan->length &&
        scan->source[cursor] == '!' && !escaped_at(scan, cursor + 1) &&
        scan->source[cursor + 1] == '[' && scan->source[cursor + 2] == '[') {
      uint32_t close = find_delimiter(scan, cursor + 3, ']', ']', false, false);
      uint32_t pipe = close == UINT32_MAX ? UINT32_MAX
        : find_unescaped_pipe(scan, cursor + 3, close);
      if (cancelled(scan)) return false;
      uint32_t target_end = pipe == UINT32_MAX ? close : pipe;
      if (close != UINT32_MAX) {
        if (target_end > cursor + 3 && !emit_wikilink(scan, cursor, 3, close, pipe, true)) return false;
        cursor = close + 2;
        continue;
      }
      scan->wikilink_disabled_until = next_line_start(scan, cursor);
    }

    if (cursor >= scan->wikilink_disabled_until &&
        scan->source[cursor] == '[' && scan->source[cursor + 1] == '[') {
      uint32_t close = find_delimiter(scan, cursor + 2, ']', ']', false, false);
      uint32_t pipe = close == UINT32_MAX ? UINT32_MAX
        : find_unescaped_pipe(scan, cursor + 2, close);
      if (cancelled(scan)) return false;
      uint32_t target_end = pipe == UINT32_MAX ? close : pipe;
      if (close != UINT32_MAX) {
        if (target_end > cursor + 2 && !emit_wikilink(scan, cursor, 2, close, pipe, false)) return false;
        cursor = close + 2;
        continue;
      }
      scan->wikilink_disabled_until = next_line_start(scan, cursor);
    }

    if (cursor >= scan->highlight_disabled_until &&
        scan->source[cursor] == '=' && scan->source[cursor + 1] == '=' &&
        (cursor == 0 || scan->source[cursor - 1] != '=') &&
        (cursor + 2 < scan->length && scan->source[cursor + 2] != '=' &&
          !whitespace(scan->source[cursor + 2]))) {
      uint32_t close = find_delimiter(scan, cursor + 2, '=', '=', false, true);
      if (close != UINT32_MAX && close > cursor + 2 &&
          (close + 2 >= scan->length || scan->source[close + 2] != '=')) {
        scan->active_match_id = scan->next_match_id++;
        if (!emit(scan, "span.highlight", cursor, close + 2) ||
            !emit(scan, "marker.highlight_open", cursor, cursor + 2) ||
            !emit(scan, "content.highlight", cursor + 2, close) ||
            !emit(scan, "marker.highlight_close", close, close + 2)) return false;
        cursor = close + 2;
        continue;
      }
      if (close == UINT32_MAX) scan->highlight_disabled_until = next_line_start(scan, cursor);
    }
    cursor++;
  }
  return !cancelled(scan);
}

bool anvil_markdown_extensions_scan(
  const AnvilTSSnapshot *snapshot,
  const AnvilMarkdownExclusion *exclusions,
  uint32_t exclusion_count,
  AnvilMarkdownExtensionCaptureCallback capture_callback,
  void *capture_payload,
  AnvilMarkdownExtensionCancelCallback cancel_callback,
  void *cancel_payload
) {
  if (!snapshot || !capture_callback) return false;
  ExtensionScan scan = {
    .source = snapshot->bytes,
    .length = snapshot->byte_len,
    .exclusions = exclusions,
    .exclusion_count = exclusion_count,
    .capture_callback = capture_callback,
    .capture_payload = capture_payload,
    .cancel_callback = cancel_callback,
    .cancel_payload = cancel_payload,
  };
  if (scan.length > 0 && memchr(scan.source, '\\', scan.length)) {
    scan.escaped = (uint8_t *)malloc(scan.length);
    if (!scan.escaped) return false;
    bool odd_backslashes = false;
    for (uint32_t i = 0; i < scan.length; i++) {
      if ((i & 0x3fff) == 0 && cancelled(&scan)) {
        free(scan.escaped);
        return false;
      }
      scan.escaped[i] = odd_backslashes ? 1 : 0;
      if (scan.source[i] == '\\') odd_backslashes = !odd_backslashes;
      else odd_backslashes = false;
    }
  }
  bool ok = scan_extensions(&scan);
  free(scan.escaped);
  free(scan.bracket_close);
  return ok;
}
