#include "text/piece_tree.h"

#include <stdlib.h>
#include <string.h>

#define PIECE_TREE_CHUNK_SIZE 4096

typedef enum PieceSource {
  PIECE_SOURCE_ORIGINAL,
  PIECE_SOURCE_ADD,
} PieceSource;

struct PieceTreeNode {
  uint32_t refcount;
  uint32_t priority;
  struct PieceTreeNode *left;
  struct PieceTreeNode *right;
  PieceSource source;
  size_t start;
  size_t len;
  size_t piece_lf_count;
  size_t subtree_len;
  size_t subtree_lf_count;
};

static size_t node_len(const PieceTreeNode *node) {
  return node ? node->subtree_len : 0;
}

static size_t node_lf_count(const PieceTreeNode *node) {
  return node ? node->subtree_lf_count : 0;
}

static size_t count_lf(const char *text, size_t len) {
  size_t count = 0;
  for (size_t i = 0; i < len; ++i) {
    count += text[i] == '\n';
  }
  return count;
}

static const char *piece_bytes(const PieceTree *tree, const PieceTreeNode *node) {
  return node->source == PIECE_SOURCE_ORIGINAL
    ? tree->original + node->start
    : tree->add + node->start;
}

static void node_refresh(PieceTreeNode *node) {
  if (!node) return;
  node->subtree_len = node_len(node->left) + node->len + node_len(node->right);
  node->subtree_lf_count = node_lf_count(node->left) + node->piece_lf_count + node_lf_count(node->right);
}

static uint32_t next_priority(PieceTree *tree) {
  uint32_t x = tree->rng_state;
  if (x == 0) x = 0x9e3779b9u;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  tree->rng_state = x;
  return x;
}

static PieceTreeNode *node_ref(PieceTreeNode *node) {
  if (node) ++node->refcount;
  return node;
}

static void node_unref(PieceTreeNode *node) {
  if (!node) return;
  if (--node->refcount != 0) return;
  node_unref(node->left);
  node_unref(node->right);
  free(node);
}

static PieceTreeNode *node_new_with_priority(
  PieceTree *tree,
  PieceSource source,
  size_t start,
  size_t len,
  uint32_t priority
) {
  if (len == 0) return NULL;
  PieceTreeNode *node = (PieceTreeNode *) calloc(1, sizeof(PieceTreeNode));
  if (!node) abort();
  node->refcount = 1;
  node->priority = priority;
  node->source = source;
  node->start = start;
  node->len = len;
  node->piece_lf_count = count_lf(piece_bytes(tree, node), len);
  node_refresh(node);
  return node;
}

static PieceTreeNode *node_new(
  PieceTree *tree,
  PieceSource source,
  size_t start,
  size_t len
) {
  return node_new_with_priority(tree, source, start, len, next_priority(tree));
}

static PieceTreeNode *node_clone_owned(
  const PieceTreeNode *node,
  PieceTreeNode *left,
  PieceTreeNode *right
) {
  if (!node) {
    node_unref(left);
    node_unref(right);
    return NULL;
  }
  PieceTreeNode *copy = (PieceTreeNode *) calloc(1, sizeof(PieceTreeNode));
  if (!copy) abort();
  *copy = *node;
  copy->refcount = 1;
  copy->left = left;
  copy->right = right;
  node_refresh(copy);
  return copy;
}

static PieceTreeNode *merge_nodes(PieceTree *tree, PieceTreeNode *left, PieceTreeNode *right) {
  (void) tree;
  if (!left) return right;
  if (!right) return left;

  if (left->priority <= right->priority) {
    PieceTreeNode *merged_right = merge_nodes(tree, node_ref(left->right), right);
    PieceTreeNode *result = node_clone_owned(left, node_ref(left->left), merged_right);
    node_unref(left);
    return result;
  }

  PieceTreeNode *merged_left = merge_nodes(tree, left, node_ref(right->left));
  PieceTreeNode *result = node_clone_owned(right, merged_left, node_ref(right->right));
  node_unref(right);
  return result;
}

static PieceTreeNode *node_chain_new(PieceTree *tree, PieceSource source, size_t start, size_t len) {
  PieceTreeNode *root = NULL;
  size_t remaining = len;
  size_t offset = start;
  while (remaining > 0) {
    size_t chunk_len = remaining > PIECE_TREE_CHUNK_SIZE ? PIECE_TREE_CHUNK_SIZE : remaining;
    PieceTreeNode *chunk = node_new(tree, source, offset, chunk_len);
    root = merge_nodes(tree, root, chunk);
    offset += chunk_len;
    remaining -= chunk_len;
  }
  return root;
}

static void split_node(
  PieceTree *tree,
  PieceTreeNode *node,
  size_t offset,
  PieceTreeNode **left_out,
  PieceTreeNode **right_out
) {
  if (!node) {
    *left_out = NULL;
    *right_out = NULL;
    return;
  }

  size_t left_len = node_len(node->left);
  size_t piece_end = left_len + node->len;

  if (offset < left_len) {
    PieceTreeNode *split_left = NULL;
    PieceTreeNode *split_right = NULL;
    split_node(tree, node->left, offset, &split_left, &split_right);
    *left_out = split_left;
    *right_out = node_clone_owned(node, split_right, node_ref(node->right));
    return;
  }

  if (offset > piece_end) {
    PieceTreeNode *split_left = NULL;
    PieceTreeNode *split_right = NULL;
    split_node(tree, node->right, offset - piece_end, &split_left, &split_right);
    *left_out = node_clone_owned(node, node_ref(node->left), split_left);
    *right_out = split_right;
    return;
  }

  if (offset == left_len) {
    *left_out = node_ref(node->left);
    *right_out = node_clone_owned(node, NULL, node_ref(node->right));
    return;
  }

  if (offset == piece_end) {
    *left_out = node_clone_owned(node, node_ref(node->left), NULL);
    *right_out = node_ref(node->right);
    return;
  }

  size_t piece_split = offset - left_len;
  PieceTreeNode *left_piece = node_new_with_priority(
    tree,
    node->source,
    node->start,
    piece_split,
    node->priority
  );
  PieceTreeNode *right_piece = node_new_with_priority(
    tree,
    node->source,
    node->start + piece_split,
    node->len - piece_split,
    node->priority
  );
  *left_out = merge_nodes(tree, node_ref(node->left), left_piece);
  *right_out = merge_nodes(tree, right_piece, node_ref(node->right));
}

static bool append_add_bytes(PieceTree *tree, const char *text, size_t len, size_t *start_out) {
  *start_out = tree->add_len;
  if (len == 0) return true;
  if (!text) return false;
  if (tree->add_len > SIZE_MAX - len) return false;
  size_t needed = tree->add_len + len;
  if (needed > tree->add_cap) {
    size_t new_cap = tree->add_cap ? tree->add_cap : 64;
    while (new_cap < needed) {
      if (new_cap > SIZE_MAX / 2) {
        new_cap = needed;
        break;
      }
      new_cap *= 2;
    }
    char *new_add = (char *) realloc(tree->add, new_cap);
    if (!new_add) return false;
    tree->add = new_add;
    tree->add_cap = new_cap;
  }
  memcpy(tree->add + tree->add_len, text, len);
  tree->add_len += len;
  return true;
}

static void flatten_node(const PieceTree *tree, const PieceTreeNode *node, char *out, size_t *offset) {
  if (!node) return;
  flatten_node(tree, node->left, out, offset);
  memcpy(out + *offset, piece_bytes(tree, node), node->len);
  *offset += node->len;
  flatten_node(tree, node->right, out, offset);
}

static bool node_byte_at(const PieceTree *tree, const PieceTreeNode *node, size_t offset, char *byte_out) {
  if (!tree || !node || !byte_out) return false;
  size_t left_len = node_len(node->left);
  if (offset < left_len) return node_byte_at(tree, node->left, offset, byte_out);
  offset -= left_len;
  if (offset < node->len) {
    *byte_out = piece_bytes(tree, node)[offset];
    return true;
  }
  return node_byte_at(tree, node->right, offset - node->len, byte_out);
}

static bool find_lf_offset(const PieceTree *tree, const PieceTreeNode *node, size_t lf_index, size_t base_offset, size_t *offset_out) {
  if (!tree || !node || !offset_out || lf_index == 0 || lf_index > node_lf_count(node)) return false;
  size_t left_lf = node_lf_count(node->left);
  if (lf_index <= left_lf) return find_lf_offset(tree, node->left, lf_index, base_offset, offset_out);
  lf_index -= left_lf;

  const char *bytes = piece_bytes(tree, node);
  size_t left_len = node_len(node->left);
  for (size_t i = 0; i < node->len; ++i) {
    if (bytes[i] == '\n') {
      if (--lf_index == 0) {
        *offset_out = base_offset + left_len + i;
        return true;
      }
    }
  }

  return find_lf_offset(tree, node->right, lf_index, base_offset + left_len + node->len, offset_out);
}

static size_t count_lfs_before_offset(const PieceTree *tree, const PieceTreeNode *node, size_t offset) {
  if (!tree || !node || offset == 0) return 0;
  size_t left_len = node_len(node->left);
  if (offset <= left_len) return count_lfs_before_offset(tree, node->left, offset);

  size_t count = node_lf_count(node->left);
  offset -= left_len;

  const char *bytes = piece_bytes(tree, node);
  size_t piece_len = offset < node->len ? offset : node->len;
  count += count_lf(bytes, piece_len);
  offset -= piece_len;

  if (offset > 0) count += count_lfs_before_offset(tree, node->right, offset);
  return count;
}

static bool walk_node_range(
  const PieceTree *tree,
  const PieceTreeNode *node,
  size_t node_start,
  size_t start_offset,
  size_t end_offset,
  PieceTreeRangeCallback callback,
  void *user
) {
  if (!tree || !node || !callback || start_offset >= end_offset) return true;

  size_t left_len = node_len(node->left);
  size_t piece_start = node_start + left_len;
  size_t piece_end = piece_start + node->len;
  size_t node_end = node_start + node->subtree_len;

  if (start_offset < piece_start) {
    if (!walk_node_range(tree, node->left, node_start, start_offset, end_offset, callback, user)) return false;
  }

  size_t chunk_start = start_offset > piece_start ? start_offset : piece_start;
  size_t chunk_end = end_offset < piece_end ? end_offset : piece_end;
  if (chunk_start < chunk_end) {
    if (!callback(piece_bytes(tree, node) + (chunk_start - piece_start), chunk_end - chunk_start, chunk_start, user)) return false;
  }

  if (end_offset > piece_end && piece_end < node_end) {
    if (!walk_node_range(tree, node->right, piece_end, start_offset, end_offset, callback, user)) return false;
  }
  return true;
}

bool piece_tree_init(PieceTree *tree, const char *text, size_t len) {
  if (!tree) return false;
  memset(tree, 0, sizeof(*tree));
  tree->rng_state = 0x12345678u;
  if (len > 0) {
    if (!text) return false;
    tree->original = (char *) malloc(len);
    if (!tree->original) return false;
    memcpy(tree->original, text, len);
    tree->original_len = len;
    tree->root = node_chain_new(tree, PIECE_SOURCE_ORIGINAL, 0, len);
  }
  return true;
}

void piece_tree_dispose(PieceTree *tree) {
  if (!tree) return;
  node_unref(tree->root);
  free(tree->original);
  free(tree->add);
  memset(tree, 0, sizeof(*tree));
}

size_t piece_tree_len(const PieceTree *tree) {
  return tree ? node_len(tree->root) : 0;
}

size_t piece_tree_lf_count(const PieceTree *tree) {
  return tree ? node_lf_count(tree->root) : 0;
}

size_t piece_tree_line_count(const PieceTree *tree) {
  if (!tree) return 0;
  return piece_tree_lf_count(tree) + 1;
}

bool piece_tree_insert(PieceTree *tree, size_t offset, const char *text, size_t len) {
  if (!tree) return false;
  if (offset > piece_tree_len(tree)) return false;
  if (len == 0) return true;

  size_t add_start = 0;
  if (!append_add_bytes(tree, text, len, &add_start)) return false;
  PieceTreeNode *inserted = node_chain_new(tree, PIECE_SOURCE_ADD, add_start, len);
  PieceTreeNode *left = NULL;
  PieceTreeNode *right = NULL;
  split_node(tree, tree->root, offset, &left, &right);
  PieceTreeNode *new_root = merge_nodes(tree, merge_nodes(tree, left, inserted), right);
  node_unref(tree->root);
  tree->root = new_root;
  return true;
}

bool piece_tree_remove(PieceTree *tree, size_t offset, size_t len) {
  if (!tree) return false;
  size_t tree_len = piece_tree_len(tree);
  if (offset > tree_len || len > tree_len - offset) return false;
  if (len == 0) return true;

  PieceTreeNode *left = NULL;
  PieceTreeNode *rest = NULL;
  PieceTreeNode *removed = NULL;
  PieceTreeNode *right = NULL;
  split_node(tree, tree->root, offset, &left, &rest);
  split_node(tree, rest, len, &removed, &right);
  node_unref(rest);
  node_unref(removed);
  PieceTreeNode *new_root = merge_nodes(tree, left, right);
  node_unref(tree->root);
  tree->root = new_root;
  return true;
}

char *piece_tree_to_string(const PieceTree *tree, size_t *len_out) {
  if (!tree) return NULL;
  size_t len = piece_tree_len(tree);
  char *text = (char *) malloc(len + 1);
  if (!text) return NULL;
  size_t offset = 0;
  flatten_node(tree, tree->root, text, &offset);
  text[len] = '\0';
  if (len_out) *len_out = len;
  return text;
}

typedef struct RangeStringBuilder {
  char *text;
  size_t start_offset;
  size_t len;
} RangeStringBuilder;

static bool append_range_string_chunk(const char *bytes, size_t len, size_t offset, void *user) {
  RangeStringBuilder *builder = (RangeStringBuilder *) user;
  memcpy(builder->text + (offset - builder->start_offset), bytes, len);
  builder->len += len;
  return true;
}

char *piece_tree_range_to_string(const PieceTree *tree, size_t start_offset, size_t end_offset, size_t *len_out) {
  if (!tree) return NULL;
  size_t tree_len = piece_tree_len(tree);
  if (start_offset > end_offset || end_offset > tree_len) return NULL;

  size_t len = end_offset - start_offset;
  char *text = (char *) malloc(len + 1);
  if (!text) return NULL;

  RangeStringBuilder builder;
  builder.text = text;
  builder.start_offset = start_offset;
  builder.len = 0;
  if (!piece_tree_walk_range(tree, start_offset, end_offset, append_range_string_chunk, &builder)) {
    free(text);
    return NULL;
  }

  text[len] = '\0';
  if (len_out) *len_out = len;
  return text;
}

bool piece_tree_walk_range(const PieceTree *tree, size_t start_offset, size_t end_offset, PieceTreeRangeCallback callback, void *user) {
  if (!tree || !callback) return false;
  size_t tree_len = piece_tree_len(tree);
  if (start_offset > end_offset || end_offset > tree_len) return false;
  if (start_offset == end_offset) return true;
  return walk_node_range(tree, tree->root, 0, start_offset, end_offset, callback, user);
}

bool piece_tree_byte_at(const PieceTree *tree, size_t offset, char *byte_out) {
  if (!tree || !byte_out) return false;
  if (offset >= piece_tree_len(tree)) return false;
  return node_byte_at(tree, tree->root, offset, byte_out);
}

bool piece_tree_walker_init(PieceTreeWalker *walker, const PieceTree *tree, size_t offset) {
  if (!walker || !tree) return false;
  if (offset > piece_tree_len(tree)) return false;
  walker->tree = tree;
  walker->offset = offset;
  return true;
}

bool piece_tree_walker_next(PieceTreeWalker *walker, char *byte_out, size_t *offset_out) {
  if (!walker || !walker->tree || !byte_out) return false;
  if (walker->offset >= piece_tree_len(walker->tree)) return false;
  size_t offset = walker->offset;
  if (!piece_tree_byte_at(walker->tree, offset, byte_out)) return false;
  if (offset_out) *offset_out = offset;
  walker->offset = offset + 1;
  return true;
}

bool piece_tree_reverse_walker_init(PieceTreeWalker *walker, const PieceTree *tree, size_t offset) {
  if (!walker || !tree) return false;
  if (offset > piece_tree_len(tree)) return false;
  walker->tree = tree;
  walker->offset = offset;
  return true;
}

bool piece_tree_walker_prev(PieceTreeWalker *walker, char *byte_out, size_t *offset_out) {
  if (!walker || !walker->tree || !byte_out) return false;
  if (walker->offset == 0) return false;
  size_t offset = walker->offset - 1;
  if (!piece_tree_byte_at(walker->tree, offset, byte_out)) return false;
  if (offset_out) *offset_out = offset;
  walker->offset = offset;
  return true;
}

bool piece_tree_line_start(const PieceTree *tree, size_t line, size_t *offset_out) {
  if (!tree || !offset_out) return false;
  if (line >= piece_tree_line_count(tree)) return false;
  if (line == 0) {
    *offset_out = 0;
    return true;
  }

  size_t lf_offset = 0;
  if (!find_lf_offset(tree, tree->root, line, 0, &lf_offset)) return false;
  *offset_out = lf_offset + 1;
  return true;
}

bool piece_tree_line_range_with_newline(const PieceTree *tree, size_t line, PieceTreeLineRange *out) {
  if (!tree || !out) return false;
  size_t line_count = piece_tree_line_count(tree);
  if (line >= line_count) return false;

  size_t start = 0;
  size_t end = 0;
  if (!piece_tree_line_start(tree, line, &start)) return false;
  if (line + 1 < line_count) {
    if (!piece_tree_line_start(tree, line + 1, &end)) return false;
  } else {
    end = piece_tree_len(tree);
  }

  out->start = start;
  out->end = end;
  return true;
}

bool piece_tree_line_range(const PieceTree *tree, size_t line, PieceTreeLineRange *out) {
  if (!tree || !out) return false;
  PieceTreeLineRange range;
  if (!piece_tree_line_range_with_newline(tree, line, &range)) return false;

  char ch = 0;
  if (range.end > range.start && piece_tree_byte_at(tree, range.end - 1, &ch) && ch == '\n') {
    --range.end;
  }

  *out = range;
  return true;
}

bool piece_tree_line_range_crlf(const PieceTree *tree, size_t line, PieceTreeLineRange *out) {
  if (!tree || !out) return false;
  PieceTreeLineRange range;
  if (!piece_tree_line_range_with_newline(tree, line, &range)) return false;

  char ch = 0;
  bool had_lf = false;
  if (range.end > range.start && piece_tree_byte_at(tree, range.end - 1, &ch) && ch == '\n') {
    --range.end;
    had_lf = true;
  }
  if (had_lf && range.end > range.start && piece_tree_byte_at(tree, range.end - 1, &ch) && ch == '\r') {
    --range.end;
  }

  *out = range;
  return true;
}

bool piece_tree_offset_to_line_col(const PieceTree *tree, size_t offset, PieceTreeLineCol *out) {
  if (!tree || !out) return false;
  if (offset > piece_tree_len(tree)) return false;

  size_t line = count_lfs_before_offset(tree, tree->root, offset);
  size_t line_start = 0;
  if (line > 0) {
    size_t lf_offset = 0;
    if (!find_lf_offset(tree, tree->root, line, 0, &lf_offset)) return false;
    line_start = lf_offset + 1;
  }

  out->line = line;
  out->col = offset - line_start;
  return true;
}

bool piece_tree_line_col_to_offset(const PieceTree *tree, size_t line, size_t col, size_t *offset_out) {
  if (!tree || !offset_out) return false;
  size_t start = 0;
  if (!piece_tree_line_start(tree, line, &start)) return false;

  PieceTreeWalker walker;
  if (!piece_tree_walker_init(&walker, tree, start)) return false;

  size_t offset = start;
  size_t remaining_col = col;
  while (remaining_col > 0) {
    char ch = 0;
    size_t byte_offset = 0;
    if (!piece_tree_walker_next(&walker, &ch, &byte_offset) || ch == '\n') return false;
    offset = byte_offset + 1;
    --remaining_col;
  }

  *offset_out = offset;
  return true;
}

PieceTreeSnapshot piece_tree_snapshot_acquire(const PieceTree *tree) {
  PieceTreeSnapshot snapshot;
  snapshot.root = tree ? node_ref(tree->root) : NULL;
  return snapshot;
}

void piece_tree_snapshot_release(PieceTreeSnapshot *snapshot) {
  if (!snapshot) return;
  node_unref(snapshot->root);
  snapshot->root = NULL;
}

bool piece_tree_restore_snapshot(PieceTree *tree, const PieceTreeSnapshot *snapshot) {
  if (!tree || !snapshot) return false;
  PieceTreeNode *new_root = node_ref(snapshot->root);
  node_unref(tree->root);
  tree->root = new_root;
  return true;
}

bool piece_tree_matches_snapshot(const PieceTree *tree, const PieceTreeSnapshot *snapshot) {
  if (!tree || !snapshot) return false;
  return tree->root == snapshot->root;
}

static bool check_node_invariants(const PieceTreeNode *node, size_t *len_out, size_t *lf_out) {
  if (!node) {
    *len_out = 0;
    *lf_out = 0;
    return true;
  }

  if (node->refcount == 0 || node->len == 0) return false;
  if (node->left && node->left->priority < node->priority) return false;
  if (node->right && node->right->priority < node->priority) return false;

  size_t left_len = 0;
  size_t left_lf = 0;
  size_t right_len = 0;
  size_t right_lf = 0;
  if (!check_node_invariants(node->left, &left_len, &left_lf)) return false;
  if (!check_node_invariants(node->right, &right_len, &right_lf)) return false;

  size_t expected_len = left_len + node->len + right_len;
  size_t expected_lf = left_lf + node->piece_lf_count + right_lf;
  if (node->subtree_len != expected_len) return false;
  if (node->subtree_lf_count != expected_lf) return false;

  *len_out = expected_len;
  *lf_out = expected_lf;
  return true;
}

bool piece_tree_check_invariants(const PieceTree *tree) {
  if (!tree) return false;
  size_t len = 0;
  size_t lf = 0;
  return check_node_invariants(tree->root, &len, &lf);
}
