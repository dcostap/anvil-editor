#ifndef ANVIL_MARKDOWN_PARSER_H
#define ANVIL_MARKDOWN_PARSER_H

#include <stdbool.h>
#include <stdint.h>

#include <tree_sitter/api.h>

#include "treesitter/snapshot.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilMarkdownTree AnvilMarkdownTree;

AnvilMarkdownTree *anvil_markdown_tree_parse(
  AnvilTSSnapshot *snapshot,
  uint32_t timeout_ms,
  char **error
);
void anvil_markdown_tree_free(AnvilMarkdownTree *tree);

const AnvilTSSnapshot *anvil_markdown_tree_snapshot(const AnvilMarkdownTree *tree);
TSTree *anvil_markdown_tree_block_tree(const AnvilMarkdownTree *tree);
uint32_t anvil_markdown_tree_inline_count(const AnvilMarkdownTree *tree);
TSTree *anvil_markdown_tree_inline_tree(const AnvilMarkdownTree *tree, uint32_t index);
TSRange anvil_markdown_tree_inline_source_range(const AnvilMarkdownTree *tree, uint32_t index);

#ifdef __cplusplus
}
#endif

#endif
