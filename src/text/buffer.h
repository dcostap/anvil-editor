#ifndef ANVIL_TEXT_BUFFER_H
#define ANVIL_TEXT_BUFFER_H

#include "text/piece_tree.h"
#include "text/undo_graph.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct NativeTreeSitter NativeTreeSitter;
typedef struct NativeTreeSitterHighlightSpan NativeTreeSitterHighlightSpan;

typedef enum BufferLineEndingMode {
  BUFFER_LINE_ENDING_LF,
  BUFFER_LINE_ENDING_CRLF,
} BufferLineEndingMode;

typedef struct BufferVisibleLine {
  size_t line;
  size_t start_offset;
  size_t end_offset;
  char *text;
  size_t text_len;
} BufferVisibleLine;

typedef struct Buffer {
  PieceTree tree;
  char *path;
  BufferLineEndingMode line_ending_mode;
  PieceTreeSnapshot clean_snapshot;
  bool has_clean_snapshot;
  UndoRedoGraph undo_graph;
  bool has_undo_graph;
  NativeTreeSitter *treesitter;
} Buffer;

typedef PieceTreeLineCol BufferLineCol;
typedef PieceTreeLineRange BufferLineRange;

bool buffer_init(Buffer *buffer, const char *bytes, size_t len);
void buffer_dispose(Buffer *buffer);

bool buffer_load_bytes(Buffer *buffer, const char *bytes, size_t len);
bool buffer_load_file(Buffer *buffer, const char *path);
bool buffer_save_file(Buffer *buffer, const char *path);
bool buffer_set_path(Buffer *buffer, const char *path);
const char *buffer_path(const Buffer *buffer);

size_t buffer_len(const Buffer *buffer);
size_t buffer_line_count(const Buffer *buffer);
BufferLineEndingMode buffer_line_ending_mode(const Buffer *buffer);
bool buffer_set_line_ending_mode(Buffer *buffer, BufferLineEndingMode mode);
const char *buffer_line_ending_bytes(const Buffer *buffer, size_t *len_out);
void buffer_refresh_line_ending_mode(Buffer *buffer);

char *buffer_to_string(const Buffer *buffer, size_t *len_out);
char *buffer_range_to_string(const Buffer *buffer, size_t start_offset, size_t end_offset, size_t *len_out);
char *buffer_get_line(const Buffer *buffer, size_t line, size_t *len_out);
BufferVisibleLine *buffer_visible_lines(const Buffer *buffer, size_t first_line, size_t last_line, size_t *count_out);
void buffer_visible_lines_free(BufferVisibleLine *lines, size_t count);

bool buffer_line_start(const Buffer *buffer, size_t line, size_t *offset_out);
bool buffer_line_range(const Buffer *buffer, size_t line, BufferLineRange *out);
bool buffer_line_range_crlf(const Buffer *buffer, size_t line, BufferLineRange *out);
bool buffer_line_range_with_newline(const Buffer *buffer, size_t line, BufferLineRange *out);
bool buffer_offset_to_line_col(const Buffer *buffer, size_t offset, BufferLineCol *out);
bool buffer_line_col_to_offset(const Buffer *buffer, size_t line, size_t col, size_t *offset_out);

void buffer_mark_clean(Buffer *buffer);
bool buffer_is_dirty(const Buffer *buffer);
bool buffer_update_undo(Buffer *buffer, size_t op_offset);
bool buffer_snap_to_undo_node(Buffer *buffer, UndoRedoNode *target, size_t *op_offset_out);
bool buffer_can_undo(const Buffer *buffer);
bool buffer_can_redo(const Buffer *buffer);
bool buffer_undo(Buffer *buffer);
bool buffer_redo(Buffer *buffer);
bool buffer_undo_op_offset(Buffer *buffer, size_t *op_offset_out);
bool buffer_redo_op_offset(Buffer *buffer, size_t *op_offset_out);

bool buffer_enable_tree_sitter(Buffer *buffer, const char *language_name);
void buffer_disable_tree_sitter(Buffer *buffer);
const char *buffer_tree_sitter_language_name(const Buffer *buffer);
const char *buffer_tree_sitter_root_kind(const Buffer *buffer);
NativeTreeSitterHighlightSpan *buffer_tree_sitter_highlights(
  Buffer *buffer,
  size_t start_offset,
  size_t end_offset,
  size_t *count_out
);
void buffer_tree_sitter_highlights_free(NativeTreeSitterHighlightSpan *spans, size_t count);

#endif
