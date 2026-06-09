#ifndef ANVIL_TEXT_BUFFER_H
#define ANVIL_TEXT_BUFFER_H

#include "text/piece_tree.h"
#include "text/undo_graph.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct Buffer {
  PieceTree tree;
  char *path;
  PieceTreeSnapshot clean_snapshot;
  bool has_clean_snapshot;
  UndoRedoGraph undo_graph;
  bool has_undo_graph;
} Buffer;

typedef PieceTreeLineCol BufferLineCol;

bool buffer_init(Buffer *buffer, const char *bytes, size_t len);
void buffer_dispose(Buffer *buffer);

bool buffer_load_bytes(Buffer *buffer, const char *bytes, size_t len);

size_t buffer_len(const Buffer *buffer);
size_t buffer_line_count(const Buffer *buffer);

char *buffer_to_string(const Buffer *buffer, size_t *len_out);
char *buffer_get_line(const Buffer *buffer, size_t line, size_t *len_out);

bool buffer_line_start(const Buffer *buffer, size_t line, size_t *offset_out);
bool buffer_offset_to_line_col(const Buffer *buffer, size_t offset, BufferLineCol *out);
bool buffer_line_col_to_offset(const Buffer *buffer, size_t line, size_t col, size_t *offset_out);

void buffer_mark_clean(Buffer *buffer);
bool buffer_is_dirty(const Buffer *buffer);
bool buffer_can_undo(const Buffer *buffer);
bool buffer_can_redo(const Buffer *buffer);
bool buffer_undo(Buffer *buffer);
bool buffer_redo(Buffer *buffer);

#endif
