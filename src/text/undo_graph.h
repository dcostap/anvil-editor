#ifndef ANVIL_TEXT_UNDO_GRAPH_H
#define ANVIL_TEXT_UNDO_GRAPH_H

#include "text/piece_tree.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct UndoRedoNode UndoRedoNode;

struct UndoRedoNode {
  UndoRedoNode *parent;
  UndoRedoNode *first_child;
  UndoRedoNode *last_child;
  UndoRedoNode *next_sibling;
  size_t child_count;
  PieceTreeSnapshot snapshot;
  size_t op_offset;
};

typedef struct UndoRedoGraph {
  UndoRedoNode *root;
  UndoRedoNode *current;
  UndoRedoNode *save_at;
} UndoRedoGraph;

bool undo_graph_init(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset);
void undo_graph_dispose(UndoRedoGraph *graph);

UndoRedoNode *undo_graph_commit(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset);
bool undo_graph_update_current_snapshot(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset);

bool undo_graph_can_undo(const UndoRedoGraph *graph);
bool undo_graph_can_redo(const UndoRedoGraph *graph);
bool undo_graph_undo(UndoRedoGraph *graph, PieceTree *tree, size_t *op_offset_out);
bool undo_graph_redo(UndoRedoGraph *graph, PieceTree *tree, size_t *op_offset_out);

void undo_graph_mark_save(UndoRedoGraph *graph);
bool undo_graph_is_dirty(const UndoRedoGraph *graph);

#endif
