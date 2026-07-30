#ifndef ANVIL_PROJECT_FILE_MANIFEST_H
#define ANVIL_PROJECT_FILE_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct AnvilProjectFileManifestSnapshot AnvilProjectFileManifestSnapshot;
typedef bool (*AnvilManifestCancelledFn)(void *userdata);

typedef enum AnvilManifestEntryKind {
  ANVIL_MANIFEST_DIRECTORY = 1,
  ANVIL_MANIFEST_MARKDOWN,
  ANVIL_MANIFEST_ATTACHMENT,
  ANVIL_MANIFEST_OTHER_FILE,
} AnvilManifestEntryKind;

typedef struct AnvilProjectFileManifestBuildSpec {
  const char *root;
  const AnvilProjectFileManifestSnapshot *previous;
  const char *const *scan_paths;
  uint32_t scan_path_count;
  const char *const *remove_paths;
  uint32_t remove_path_count;
  bool scoped;
  bool show_unsupported_files;
  AnvilManifestCancelledFn cancelled;
  void *cancel_userdata;
} AnvilProjectFileManifestBuildSpec;

typedef struct AnvilProjectFileManifestRecord {
  const char *absolute_path;
  const char *relative_path;
  AnvilManifestEntryKind kind;
  uint64_t size;
  int64_t modified;
} AnvilProjectFileManifestRecord;

typedef struct AnvilProjectFileManifestSummary {
  uint64_t records;
  uint64_t files;
  uint64_t directories;
  uint64_t markdown_files;
  uint64_t attachments;
  uint64_t other_files;
  uint64_t inaccessible_entries;
  uint64_t total_bytes;
  double scan_ms;
} AnvilProjectFileManifestSummary;

AnvilProjectFileManifestSnapshot *anvil_project_file_manifest_build(
  const AnvilProjectFileManifestBuildSpec *spec, char **error);
void anvil_project_file_manifest_retain(AnvilProjectFileManifestSnapshot *snapshot);
void anvil_project_file_manifest_release(AnvilProjectFileManifestSnapshot *snapshot);
void anvil_project_file_manifest_summary(const AnvilProjectFileManifestSnapshot *snapshot,
  AnvilProjectFileManifestSummary *summary);
uint64_t anvil_project_file_manifest_count(const AnvilProjectFileManifestSnapshot *snapshot);
bool anvil_project_file_manifest_record_at(const AnvilProjectFileManifestSnapshot *snapshot,
  uint64_t index, AnvilProjectFileManifestRecord *record);
bool anvil_project_file_manifest_lookup(const AnvilProjectFileManifestSnapshot *snapshot,
  const char *relative_path, AnvilProjectFileManifestRecord *record);
const char *anvil_manifest_entry_kind_name(AnvilManifestEntryKind kind);

#endif
