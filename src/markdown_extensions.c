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
  return ok;
}
