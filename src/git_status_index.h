#ifndef ANVIL_GIT_STATUS_INDEX_H
#define ANVIL_GIT_STATUS_INDEX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct AnvilGitStatusSnapshot AnvilGitStatusSnapshot;
typedef bool (*AnvilGitStatusCancelledFn)(void *userdata);

typedef enum AnvilGitStatusKind {
  ANVIL_GIT_STATUS_NONE = 0,
  ANVIL_GIT_STATUS_IGNORED,
  ANVIL_GIT_STATUS_UNTRACKED,
  ANVIL_GIT_STATUS_MODIFIED,
  ANVIL_GIT_STATUS_RENAMED,
  ANVIL_GIT_STATUS_COPIED,
  ANVIL_GIT_STATUS_TYPECHANGE,
  ANVIL_GIT_STATUS_UNMERGED,
  ANVIL_GIT_STATUS_ADDED,
  ANVIL_GIT_STATUS_DELETED,
} AnvilGitStatusKind;

typedef struct AnvilGitStatusBuildSpec {
  const char *repository_root;
  const char *status_text;
  size_t status_text_len;
  const char *numstat_text;
  size_t numstat_text_len;
  bool case_insensitive_paths;
  AnvilGitStatusCancelledFn cancelled;
  void *cancel_userdata;
} AnvilGitStatusBuildSpec;

typedef struct AnvilGitStatusLookup {
  AnvilGitStatusKind kind;
  bool has_numstat;
  uint64_t additions;
  uint64_t deletions;
} AnvilGitStatusLookup;

typedef struct AnvilGitStatusSummary {
  uint64_t status_bytes;
  uint64_t numstat_bytes;
  uint64_t status_records;
  uint64_t numstat_records;
  uint64_t parent_edges;
  uint64_t subtree_summaries;
  uint64_t rejected_records;
  uint64_t entry_count;
  double build_ms;
} AnvilGitStatusSummary;

AnvilGitStatusSnapshot *anvil_git_status_snapshot_build(const AnvilGitStatusBuildSpec *spec, char **error);
void anvil_git_status_snapshot_retain(AnvilGitStatusSnapshot *snapshot);
void anvil_git_status_snapshot_release(AnvilGitStatusSnapshot *snapshot);
void anvil_git_status_snapshot_summary(const AnvilGitStatusSnapshot *snapshot, AnvilGitStatusSummary *summary);
bool anvil_git_status_snapshot_lookup(const AnvilGitStatusSnapshot *snapshot, const char *path, size_t path_len,
  bool is_directory, AnvilGitStatusLookup *lookup);
const char *anvil_git_status_kind_name(AnvilGitStatusKind kind);

#endif
