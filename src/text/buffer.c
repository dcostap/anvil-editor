#include "text/buffer.h"
#include "text/treesitter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void clear_clean_snapshot(Buffer *buffer) {
  if (buffer->has_clean_snapshot) {
    piece_tree_snapshot_release(&buffer->clean_snapshot);
    buffer->has_clean_snapshot = false;
  }
}

static void clear_undo_graph(Buffer *buffer) {
  if (buffer->has_undo_graph) {
    undo_graph_dispose(&buffer->undo_graph);
    buffer->has_undo_graph = false;
  }
}

static BufferLineEndingMode detect_line_ending_mode_from_bytes(const char *bytes, size_t len) {
  if (!bytes) return BUFFER_LINE_ENDING_LF;
  for (size_t i = 0; i < len; ++i) {
    if (bytes[i] == '\n') return i > 0 && bytes[i - 1] == '\r'
      ? BUFFER_LINE_ENDING_CRLF
      : BUFFER_LINE_ENDING_LF;
  }
  return BUFFER_LINE_ENDING_LF;
}

static char *buffer_strdup(const char *text) {
  if (!text) return NULL;
  size_t len = strlen(text);
  char *copy = (char *) malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, text, len + 1);
  return copy;
}

bool buffer_init(Buffer *buffer, const char *bytes, size_t len) {
  if (!buffer) return false;
  memset(buffer, 0, sizeof(*buffer));
  if (!piece_tree_init(&buffer->tree, bytes, len)) return false;
  buffer->line_ending_mode = detect_line_ending_mode_from_bytes(bytes, len);
  if (!undo_graph_init(&buffer->undo_graph, &buffer->tree, 0)) {
    piece_tree_dispose(&buffer->tree);
    return false;
  }
  buffer->has_undo_graph = true;
  buffer_mark_clean(buffer);
  return true;
}

void buffer_dispose(Buffer *buffer) {
  if (!buffer) return;
  clear_clean_snapshot(buffer);
  clear_undo_graph(buffer);
  free(buffer->path);
  native_treesitter_free(buffer->treesitter);
  buffer->treesitter = NULL;
  piece_tree_dispose(&buffer->tree);
  memset(buffer, 0, sizeof(*buffer));
}

bool buffer_load_bytes(Buffer *buffer, const char *bytes, size_t len) {
  if (!buffer) return false;
  clear_clean_snapshot(buffer);
  clear_undo_graph(buffer);
  free(buffer->path);
  buffer->path = NULL;
  native_treesitter_free(buffer->treesitter);
  buffer->treesitter = NULL;
  piece_tree_dispose(&buffer->tree);
  if (!piece_tree_init(&buffer->tree, bytes, len)) return false;
  buffer->line_ending_mode = detect_line_ending_mode_from_bytes(bytes, len);
  if (!undo_graph_init(&buffer->undo_graph, &buffer->tree, 0)) {
    piece_tree_dispose(&buffer->tree);
    return false;
  }
  buffer->has_undo_graph = true;
  buffer_mark_clean(buffer);
  return true;
}

bool buffer_load_file(Buffer *buffer, const char *path) {
  if (!buffer || !path) return false;
  FILE *file = fopen(path, "rb");
  if (!file) return false;

  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return false;
  }
  long file_len = ftell(file);
  if (file_len < 0) {
    fclose(file);
    return false;
  }
  if (fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return false;
  }

  size_t len = (size_t) file_len;
  char *bytes = (char *) malloc(len ? len : 1);
  if (!bytes) {
    fclose(file);
    return false;
  }
  if (len > 0 && fread(bytes, 1, len, file) != len) {
    free(bytes);
    fclose(file);
    return false;
  }
  fclose(file);

  bool ok = buffer_load_bytes(buffer, bytes, len);
  free(bytes);
  if (!ok) return false;
  return buffer_set_path(buffer, path);
}

bool buffer_save_file(Buffer *buffer, const char *path) {
  if (!buffer) return false;
  const char *target_path = path ? path : buffer->path;
  if (!target_path) return false;

  size_t len = 0;
  char *bytes = buffer_to_string(buffer, &len);
  if (!bytes) return false;

  FILE *file = fopen(target_path, "wb");
  if (!file) {
    free(bytes);
    return false;
  }
  bool ok = len == 0 || fwrite(bytes, 1, len, file) == len;
  if (fclose(file) != 0) ok = false;
  free(bytes);
  if (!ok) return false;

  if (!buffer_set_path(buffer, target_path)) return false;
  buffer_mark_clean(buffer);
  return true;
}

bool buffer_set_path(Buffer *buffer, const char *path) {
  if (!buffer) return false;
  char *copy = buffer_strdup(path);
  if (path && !copy) return false;
  free(buffer->path);
  buffer->path = copy;
  return true;
}

const char *buffer_path(const Buffer *buffer) {
  return buffer ? buffer->path : NULL;
}

size_t buffer_len(const Buffer *buffer) {
  return buffer ? piece_tree_len(&buffer->tree) : 0;
}

size_t buffer_line_count(const Buffer *buffer) {
  return buffer ? piece_tree_line_count(&buffer->tree) : 0;
}

BufferLineEndingMode buffer_line_ending_mode(const Buffer *buffer) {
  return buffer ? buffer->line_ending_mode : BUFFER_LINE_ENDING_LF;
}

bool buffer_set_line_ending_mode(Buffer *buffer, BufferLineEndingMode mode) {
  if (!buffer) return false;
  if (mode != BUFFER_LINE_ENDING_LF && mode != BUFFER_LINE_ENDING_CRLF) return false;
  buffer->line_ending_mode = mode;
  return true;
}

const char *buffer_line_ending_bytes(const Buffer *buffer, size_t *len_out) {
  if (buffer_line_ending_mode(buffer) == BUFFER_LINE_ENDING_CRLF) {
    if (len_out) *len_out = 2;
    return "\r\n";
  }
  if (len_out) *len_out = 1;
  return "\n";
}

void buffer_refresh_line_ending_mode(Buffer *buffer) {
  if (!buffer) return;
  size_t len = 0;
  char *bytes = buffer_to_string(buffer, &len);
  if (!bytes) return;
  buffer->line_ending_mode = detect_line_ending_mode_from_bytes(bytes, len);
  free(bytes);
}

char *buffer_to_string(const Buffer *buffer, size_t *len_out) {
  if (!buffer) return NULL;
  return piece_tree_to_string(&buffer->tree, len_out);
}

char *buffer_range_to_string(const Buffer *buffer, size_t start_offset, size_t end_offset, size_t *len_out) {
  if (!buffer) return NULL;
  return piece_tree_range_to_string(&buffer->tree, start_offset, end_offset, len_out);
}

char *buffer_get_line(const Buffer *buffer, size_t line, size_t *len_out) {
  if (!buffer) return NULL;

  BufferLineRange range;
  if (!buffer_line_range_with_newline(buffer, line, &range)) return NULL;
  return buffer_range_to_string(buffer, range.start, range.end, len_out);
}

BufferVisibleLine *buffer_visible_lines(const Buffer *buffer, size_t first_line, size_t last_line, size_t *count_out) {
  if (count_out) *count_out = 0;
  if (!buffer) return NULL;
  size_t line_count = buffer_line_count(buffer);
  if (line_count == 0 || first_line >= line_count) return NULL;
  if (last_line >= line_count) last_line = line_count - 1;
  if (last_line < first_line) return NULL;

  size_t count = last_line - first_line + 1;
  BufferVisibleLine *lines = (BufferVisibleLine *) calloc(count, sizeof(BufferVisibleLine));
  if (!lines) return NULL;

  for (size_t i = 0; i < count; ++i) {
    size_t line = first_line + i;
    BufferLineRange range;
    if (!buffer_line_range_with_newline(buffer, line, &range)) {
      buffer_visible_lines_free(lines, i);
      return NULL;
    }
    size_t text_len = 0;
    char *text = buffer_range_to_string(buffer, range.start, range.end, &text_len);
    if (!text) {
      buffer_visible_lines_free(lines, i);
      return NULL;
    }
    lines[i].line = line;
    lines[i].start_offset = range.start;
    lines[i].end_offset = range.end;
    lines[i].text = text;
    lines[i].text_len = text_len;
  }

  if (count_out) *count_out = count;
  return lines;
}

void buffer_visible_lines_free(BufferVisibleLine *lines, size_t count) {
  if (!lines) return;
  for (size_t i = 0; i < count; ++i) free(lines[i].text);
  free(lines);
}

bool buffer_line_start(const Buffer *buffer, size_t line, size_t *offset_out) {
  if (!buffer) return false;
  return piece_tree_line_start(&buffer->tree, line, offset_out);
}

bool buffer_line_range(const Buffer *buffer, size_t line, BufferLineRange *out) {
  if (!buffer) return false;
  return piece_tree_line_range(&buffer->tree, line, out);
}

bool buffer_line_range_crlf(const Buffer *buffer, size_t line, BufferLineRange *out) {
  if (!buffer) return false;
  return piece_tree_line_range_crlf(&buffer->tree, line, out);
}

bool buffer_line_range_with_newline(const Buffer *buffer, size_t line, BufferLineRange *out) {
  if (!buffer) return false;
  return piece_tree_line_range_with_newline(&buffer->tree, line, out);
}

bool buffer_offset_to_line_col(const Buffer *buffer, size_t offset, BufferLineCol *out) {
  if (!buffer) return false;
  return piece_tree_offset_to_line_col(&buffer->tree, offset, out);
}

bool buffer_line_col_to_offset(const Buffer *buffer, size_t line, size_t col, size_t *offset_out) {
  if (!buffer) return false;
  return piece_tree_line_col_to_offset(&buffer->tree, line, col, offset_out);
}

void buffer_mark_clean(Buffer *buffer) {
  if (!buffer) return;
  clear_clean_snapshot(buffer);
  buffer->clean_snapshot = piece_tree_snapshot_acquire(&buffer->tree);
  buffer->has_clean_snapshot = true;
  if (buffer->has_undo_graph) undo_graph_mark_save(&buffer->undo_graph);
}

bool buffer_is_dirty(const Buffer *buffer) {
  if (!buffer) return false;
  if (buffer->has_undo_graph) return undo_graph_is_dirty(&buffer->undo_graph);
  if (!buffer->has_clean_snapshot) return true;
  return !piece_tree_matches_snapshot(&buffer->tree, &buffer->clean_snapshot);
}

bool buffer_update_undo(Buffer *buffer, size_t op_offset) {
  if (!buffer) return false;
  if (!buffer->has_undo_graph) {
    if (!undo_graph_init(&buffer->undo_graph, &buffer->tree, op_offset)) return false;
    buffer->has_undo_graph = true;
    return true;
  }
  return undo_graph_update_current_snapshot(&buffer->undo_graph, &buffer->tree, op_offset);
}

bool buffer_snap_to_undo_node(Buffer *buffer, UndoRedoNode *target, size_t *op_offset_out) {
  if (!buffer || !buffer->has_undo_graph) return false;
  if (!undo_graph_snap_to(&buffer->undo_graph, &buffer->tree, target, op_offset_out)) return false;
  buffer_refresh_line_ending_mode(buffer);
  if (buffer->treesitter) native_treesitter_after_snap(buffer->treesitter, buffer);
  return true;
}

bool buffer_can_undo(const Buffer *buffer) {
  return buffer && buffer->has_undo_graph && undo_graph_can_undo(&buffer->undo_graph);
}

bool buffer_can_redo(const Buffer *buffer) {
  return buffer && buffer->has_undo_graph && undo_graph_can_redo(&buffer->undo_graph);
}

bool buffer_undo(Buffer *buffer) {
  return buffer_undo_op_offset(buffer, NULL);
}

bool buffer_redo(Buffer *buffer) {
  return buffer_redo_op_offset(buffer, NULL);
}

bool buffer_undo_op_offset(Buffer *buffer, size_t *op_offset_out) {
  if (!buffer || !buffer->has_undo_graph) return false;
  if (!undo_graph_undo(&buffer->undo_graph, &buffer->tree, op_offset_out)) return false;
  buffer_refresh_line_ending_mode(buffer);
  if (buffer->treesitter) native_treesitter_after_snap(buffer->treesitter, buffer);
  return true;
}

bool buffer_redo_op_offset(Buffer *buffer, size_t *op_offset_out) {
  if (!buffer || !buffer->has_undo_graph) return false;
  if (!undo_graph_redo(&buffer->undo_graph, &buffer->tree, op_offset_out)) return false;
  buffer_refresh_line_ending_mode(buffer);
  if (buffer->treesitter) native_treesitter_after_snap(buffer->treesitter, buffer);
  return true;
}

bool buffer_enable_tree_sitter(Buffer *buffer, const char *language_name) {
  if (!buffer || !language_name) return false;
  if (!buffer->treesitter) {
    buffer->treesitter = native_treesitter_new(buffer, language_name);
    return buffer->treesitter != NULL;
  }
  return native_treesitter_set_language(buffer->treesitter, buffer, language_name);
}

void buffer_disable_tree_sitter(Buffer *buffer) {
  if (!buffer) return;
  native_treesitter_free(buffer->treesitter);
  buffer->treesitter = NULL;
}

const char *buffer_tree_sitter_language_name(const Buffer *buffer) {
  return buffer && buffer->treesitter ? native_treesitter_language_name(buffer->treesitter) : NULL;
}

const char *buffer_tree_sitter_root_kind(const Buffer *buffer) {
  return buffer && buffer->treesitter ? native_treesitter_root_kind(buffer->treesitter) : NULL;
}

NativeTreeSitterHighlightSpan *buffer_tree_sitter_highlights(
  Buffer *buffer,
  size_t start_offset,
  size_t end_offset,
  size_t *count_out
) {
  if (!buffer || !buffer->treesitter) {
    if (count_out) *count_out = 0;
    return NULL;
  }
  return native_treesitter_highlights(buffer->treesitter, start_offset, end_offset, count_out);
}

void buffer_tree_sitter_highlights_free(NativeTreeSitterHighlightSpan *spans, size_t count) {
  native_treesitter_highlights_free(spans, count);
}
