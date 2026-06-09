#include "text/buffer.h"

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
  piece_tree_dispose(&buffer->tree);
  memset(buffer, 0, sizeof(*buffer));
}

bool buffer_load_bytes(Buffer *buffer, const char *bytes, size_t len) {
  if (!buffer) return false;
  clear_clean_snapshot(buffer);
  clear_undo_graph(buffer);
  free(buffer->path);
  buffer->path = NULL;
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

  size_t start = 0;
  if (!piece_tree_line_start(&buffer->tree, line, &start)) return NULL;

  size_t end = 0;
  if (line + 1 < piece_tree_line_count(&buffer->tree)) {
    if (!piece_tree_line_start(&buffer->tree, line + 1, &end)) return NULL;
  } else {
    end = piece_tree_len(&buffer->tree);
  }

  size_t flat_len = 0;
  char *flat = piece_tree_to_string(&buffer->tree, &flat_len);
  if (!flat) return NULL;
  if (start > end || end > flat_len) {
    free(flat);
    return NULL;
  }

  size_t len = end - start;
  char *line_text = (char *) malloc(len + 1);
  if (!line_text) {
    free(flat);
    return NULL;
  }
  memcpy(line_text, flat + start, len);
  line_text[len] = '\0';
  free(flat);
  if (len_out) *len_out = len;
  return line_text;
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
  return true;
}

bool buffer_redo_op_offset(Buffer *buffer, size_t *op_offset_out) {
  if (!buffer || !buffer->has_undo_graph) return false;
  if (!undo_graph_redo(&buffer->undo_graph, &buffer->tree, op_offset_out)) return false;
  buffer_refresh_line_ending_mode(buffer);
  return true;
}
