#include "text/buffer.h"

#include <stdlib.h>
#include <string.h>

static void clear_clean_snapshot(Buffer *buffer) {
  if (buffer->has_clean_snapshot) {
    piece_tree_snapshot_release(&buffer->clean_snapshot);
    buffer->has_clean_snapshot = false;
  }
}

bool buffer_init(Buffer *buffer, const char *bytes, size_t len) {
  if (!buffer) return false;
  memset(buffer, 0, sizeof(*buffer));
  if (!piece_tree_init(&buffer->tree, bytes, len)) return false;
  buffer_mark_clean(buffer);
  return true;
}

void buffer_dispose(Buffer *buffer) {
  if (!buffer) return;
  clear_clean_snapshot(buffer);
  free(buffer->path);
  piece_tree_dispose(&buffer->tree);
  memset(buffer, 0, sizeof(*buffer));
}

bool buffer_load_bytes(Buffer *buffer, const char *bytes, size_t len) {
  if (!buffer) return false;
  clear_clean_snapshot(buffer);
  free(buffer->path);
  buffer->path = NULL;
  piece_tree_dispose(&buffer->tree);
  if (!piece_tree_init(&buffer->tree, bytes, len)) return false;
  buffer_mark_clean(buffer);
  return true;
}

size_t buffer_len(const Buffer *buffer) {
  return buffer ? piece_tree_len(&buffer->tree) : 0;
}

size_t buffer_line_count(const Buffer *buffer) {
  return buffer ? piece_tree_line_count(&buffer->tree) : 0;
}

char *buffer_to_string(const Buffer *buffer, size_t *len_out) {
  if (!buffer) return NULL;
  return piece_tree_to_string(&buffer->tree, len_out);
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
}

bool buffer_is_dirty(const Buffer *buffer) {
  if (!buffer) return false;
  if (!buffer->has_clean_snapshot) return true;
  return !piece_tree_matches_snapshot(&buffer->tree, &buffer->clean_snapshot);
}
