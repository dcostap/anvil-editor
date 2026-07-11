#ifndef ANVIL_TREESITTER_PROJECT_FILE_H
#define ANVIL_TREESITTER_PROJECT_FILE_H

#include <stdbool.h>
#include <stdint.h>

#include <tree_sitter/api.h>

#include "snapshot.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilTSProjectFileResult AnvilTSProjectFileResult;

typedef struct AnvilTSProjectCapture {
  const char *name;
  uint32_t name_len;
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
  uint32_t match_id;
  uint32_t order;
} AnvilTSProjectCapture;

typedef struct AnvilTSProjectRange {
  uint32_t start_byte;
  uint32_t end_byte;
  TSPoint start_point;
  TSPoint end_point;
} AnvilTSProjectRange;

typedef struct AnvilTSProjectSymbolView {
  const char *name;
  uint32_t name_len;
  const char *kind;
  uint32_t kind_len;
  const char *signature;
  uint32_t signature_len;
  const char *declaration;
  uint32_t declaration_len;
  uint32_t declaration_name_start;
  uint32_t declaration_name_end;
  bool has_declaration_name_span;
  AnvilTSProjectRange range;
  AnvilTSProjectRange name_range;
  uint32_t index;
  uint32_t parent;
  uint32_t depth;
  const uint32_t *children;
  uint32_t child_count;
} AnvilTSProjectSymbolView;

typedef struct AnvilTSProjectUsageView {
  const char *name;
  uint32_t name_len;
  const char *capture;
  uint32_t capture_len;
  const char *kind;
  uint32_t kind_len;
  const char *line_text;
  uint32_t line_text_len;
  bool is_declaration;
  AnvilTSProjectRange range;
} AnvilTSProjectUsageView;

AnvilTSProjectFileResult *anvil_ts_project_file_build(
  const AnvilTSSnapshot *snapshot,
  const char *path,
  const char *relpath,
  const char *language_id,
  const AnvilTSProjectCapture *outline,
  uint32_t outline_count,
  const AnvilTSProjectCapture *usages,
  uint32_t usage_count,
  char **error
);
void anvil_ts_project_file_free(AnvilTSProjectFileResult *result);
const char *anvil_ts_project_file_path(const AnvilTSProjectFileResult *result);
const char *anvil_ts_project_file_relpath(const AnvilTSProjectFileResult *result);
const char *anvil_ts_project_file_language(const AnvilTSProjectFileResult *result);
uint32_t anvil_ts_project_file_symbol_count(const AnvilTSProjectFileResult *result);
uint32_t anvil_ts_project_file_usage_count(const AnvilTSProjectFileResult *result);
bool anvil_ts_project_file_symbol_at(const AnvilTSProjectFileResult *result, uint32_t index, AnvilTSProjectSymbolView *view);
bool anvil_ts_project_file_usage_at(const AnvilTSProjectFileResult *result, uint32_t index, AnvilTSProjectUsageView *view);

#ifdef __cplusplus
}
#endif

#endif
