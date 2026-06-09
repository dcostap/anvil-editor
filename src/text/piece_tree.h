#ifndef ANVIL_TEXT_PIECE_TREE_H
#define ANVIL_TEXT_PIECE_TREE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct PieceTreeNode PieceTreeNode;

typedef struct PieceTree {
  char *original;
  size_t original_len;
  char *add;
  size_t add_len;
  size_t add_cap;
  PieceTreeNode *root;
  uint32_t rng_state;
} PieceTree;

typedef struct PieceTreeSnapshot {
  PieceTreeNode *root;
} PieceTreeSnapshot;

typedef struct PieceTreeLineCol {
  size_t line;
  size_t col;
} PieceTreeLineCol;

bool piece_tree_init(PieceTree *tree, const char *text, size_t len);
void piece_tree_dispose(PieceTree *tree);

size_t piece_tree_len(const PieceTree *tree);
size_t piece_tree_lf_count(const PieceTree *tree);
size_t piece_tree_line_count(const PieceTree *tree);

bool piece_tree_insert(PieceTree *tree, size_t offset, const char *text, size_t len);
bool piece_tree_remove(PieceTree *tree, size_t offset, size_t len);

char *piece_tree_to_string(const PieceTree *tree, size_t *len_out);
bool piece_tree_line_start(const PieceTree *tree, size_t line, size_t *offset_out);
bool piece_tree_offset_to_line_col(const PieceTree *tree, size_t offset, PieceTreeLineCol *out);
bool piece_tree_line_col_to_offset(const PieceTree *tree, size_t line, size_t col, size_t *offset_out);

PieceTreeSnapshot piece_tree_snapshot_acquire(const PieceTree *tree);
void piece_tree_snapshot_release(PieceTreeSnapshot *snapshot);
bool piece_tree_restore_snapshot(PieceTree *tree, const PieceTreeSnapshot *snapshot);

bool piece_tree_check_invariants(const PieceTree *tree);

#endif
