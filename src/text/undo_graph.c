#include "text/undo_graph.h"

#include <stdlib.h>
#include <string.h>

static UndoRedoNode *undo_node_new(const PieceTree *tree, size_t op_offset) {
  UndoRedoNode *node = (UndoRedoNode *) calloc(1, sizeof(UndoRedoNode));
  if (!node) return NULL;
  node->snapshot = piece_tree_snapshot_acquire(tree);
  node->op_offset = op_offset;
  return node;
}

static void undo_node_free_recursive(UndoRedoNode *node) {
  if (!node) return;
  UndoRedoNode *child = node->first_child;
  while (child) {
    UndoRedoNode *next = child->next_sibling;
    undo_node_free_recursive(child);
    child = next;
  }
  piece_tree_snapshot_release(&node->snapshot);
  free(node);
}

bool undo_graph_init(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset) {
  if (!graph || !tree) return false;
  memset(graph, 0, sizeof(*graph));
  graph->root = undo_node_new(tree, op_offset);
  if (!graph->root) return false;
  graph->current = graph->root;
  graph->save_at = graph->root;
  return true;
}

void undo_graph_dispose(UndoRedoGraph *graph) {
  if (!graph) return;
  undo_node_free_recursive(graph->root);
  memset(graph, 0, sizeof(*graph));
}

UndoRedoNode *undo_graph_commit(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset) {
  if (!graph || !tree) return NULL;
  if (!graph->current) {
    if (!undo_graph_init(graph, tree, op_offset)) return NULL;
    return graph->current;
  }

  UndoRedoNode *node = undo_node_new(tree, op_offset);
  if (!node) return NULL;
  node->parent = graph->current;

  if (!graph->current->first_child) {
    graph->current->first_child = node;
  } else {
    graph->current->last_child->next_sibling = node;
  }
  graph->current->last_child = node;
  graph->current->child_count += 1;
  graph->current = node;
  return node;
}

bool undo_graph_update_current_snapshot(UndoRedoGraph *graph, const PieceTree *tree, size_t op_offset) {
  if (!graph || !graph->current || !tree) return false;
  PieceTreeSnapshot snapshot = piece_tree_snapshot_acquire(tree);
  piece_tree_snapshot_release(&graph->current->snapshot);
  graph->current->snapshot = snapshot;
  graph->current->op_offset = op_offset;
  return true;
}

bool undo_graph_can_undo(const UndoRedoGraph *graph) {
  return graph && graph->current && graph->current->parent;
}

bool undo_graph_can_redo(const UndoRedoGraph *graph) {
  return graph && graph->current && graph->current->last_child;
}

bool undo_graph_undo(UndoRedoGraph *graph, PieceTree *tree, size_t *op_offset_out) {
  if (!undo_graph_can_undo(graph) || !tree) return false;
  UndoRedoNode *target = graph->current->parent;
  if (!piece_tree_restore_snapshot(tree, &target->snapshot)) return false;
  graph->current = target;
  if (op_offset_out) *op_offset_out = target->op_offset;
  return true;
}

bool undo_graph_redo(UndoRedoGraph *graph, PieceTree *tree, size_t *op_offset_out) {
  if (!undo_graph_can_redo(graph) || !tree) return false;
  UndoRedoNode *target = graph->current->last_child;
  if (!piece_tree_restore_snapshot(tree, &target->snapshot)) return false;
  graph->current = target;
  if (op_offset_out) *op_offset_out = target->op_offset;
  return true;
}

void undo_graph_mark_save(UndoRedoGraph *graph) {
  if (!graph) return;
  graph->save_at = graph->current;
}

bool undo_graph_is_dirty(const UndoRedoGraph *graph) {
  if (!graph) return false;
  return graph->current != graph->save_at;
}
