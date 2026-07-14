#ifndef ANVIL_TREESITTER_PROJECT_INDEX_H
#define ANVIL_TREESITTER_PROJECT_INDEX_H

#include <stdbool.h>
#include <stdint.h>

#include "project_file.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilTSProjectBuilder AnvilTSProjectBuilder;
typedef struct AnvilTSProjectSnapshot AnvilTSProjectSnapshot;

typedef struct AnvilTSProjectSnapshotSummary {
  const char *status;
  uint32_t files;
  uint32_t symbols;
  uint32_t usages;
  uint32_t usage_names;
  bool usage_truncated;
  bool usage_complete;
} AnvilTSProjectSnapshotSummary;

typedef struct AnvilTSProjectSnapshotFileView {
  AnvilTSProjectFileResult *file;
  const char *fingerprint;
  bool usage_complete;
} AnvilTSProjectSnapshotFileView;

AnvilTSProjectBuilder *anvil_ts_project_builder_create(uint32_t usage_cap);
AnvilTSProjectBuilder *anvil_ts_project_builder_create_from_snapshot(const AnvilTSProjectSnapshot *snapshot, uint32_t usage_cap);
void anvil_ts_project_builder_retain(AnvilTSProjectBuilder *builder);
void anvil_ts_project_builder_release(AnvilTSProjectBuilder *builder);
void anvil_ts_project_builder_close(AnvilTSProjectBuilder *builder);
uint64_t anvil_ts_project_builder_id(const AnvilTSProjectBuilder *builder);
AnvilTSProjectBuilder *anvil_ts_project_builder_open(uint64_t id);
bool anvil_ts_project_builder_adopt_batch(
  AnvilTSProjectBuilder *builder,
  AnvilTSProjectFileResult **files,
  const char *const *fingerprints,
  const bool *usage_complete,
  uint32_t count,
  char **error
);
bool anvil_ts_project_builder_adopt(
  AnvilTSProjectBuilder *builder,
  AnvilTSProjectFileResult *file,
  const char *fingerprint,
  bool usage_complete,
  char **error
);
bool anvil_ts_project_builder_remove(AnvilTSProjectBuilder *builder, const char *path);
bool anvil_ts_project_builder_fingerprint_matches(AnvilTSProjectBuilder *builder, const char *path, const char *fingerprint);
bool anvil_ts_project_builder_remove_scope_missing(
  AnvilTSProjectBuilder *builder,
  const char *const *scope_paths,
  uint32_t scope_count,
  const char *const *seen_paths,
  uint32_t seen_count,
  char **error
);
AnvilTSProjectSnapshot *anvil_ts_project_builder_snapshot(
  AnvilTSProjectBuilder *builder,
  const char *status,
  bool freeze,
  char **error
);

void anvil_ts_project_snapshot_retain(AnvilTSProjectSnapshot *snapshot);
void anvil_ts_project_snapshot_release(AnvilTSProjectSnapshot *snapshot);
void anvil_ts_project_snapshot_summary(const AnvilTSProjectSnapshot *snapshot, AnvilTSProjectSnapshotSummary *summary);
bool anvil_ts_project_snapshot_file_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectSnapshotFileView *view);
bool anvil_ts_project_snapshot_symbol_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectFileResult **file, uint32_t *file_symbol_index);
bool anvil_ts_project_snapshot_usage_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectFileResult **file, uint32_t *file_usage_index);
/* Language, kind, and parent-name filters are exact allowlists. Path filters are scope rules:
 * the longest matching included/excluded path wins, with exclusion winning
 * ties. Returned indices use snapshot order and are owned by the caller. */
bool anvil_ts_project_snapshot_query_symbols(
  const AnvilTSProjectSnapshot *snapshot,
  const char *query,
  uint32_t offset,
  uint32_t limit,
  const char *const *kinds,
  uint32_t kind_count,
  const char *const *parent_names,
  uint32_t parent_name_count,
  const char *const *languages,
  uint32_t language_count,
  const char *const *excluded_paths,
  uint32_t excluded_path_count,
  const char *const *included_paths,
  uint32_t included_path_count,
  uint32_t **indices,
  uint32_t *count,
  uint32_t *total,
  bool *has_more
);
bool anvil_ts_project_snapshot_query_usages(
  const AnvilTSProjectSnapshot *snapshot,
  const char *name,
  uint32_t name_len,
  uint32_t offset,
  uint32_t limit,
  bool include_declarations,
  const char *const *excluded_paths,
  uint32_t excluded_path_count,
  const char *const *included_paths,
  uint32_t included_path_count,
  uint32_t **indices,
  uint32_t *count,
  uint32_t *total,
  bool *has_more
);

#ifdef __cplusplus
}
#endif

#endif
