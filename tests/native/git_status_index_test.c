#include "git_status_index.h"

#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)

static int cancel_checks;
static bool cancel_after_first(void *userdata) {
  (void)userdata;
  cancel_checks++;
  return cancel_checks > 1;
}

int main(void) {
  CHECK(SDL_Init(0));

  static const char status[] =
    " M src/app.lua\0"
    "A  src/new.lua\0"
    "!! build/\0"
    "?? scratch/\0"
    "R  src/renamed.lua\0src/old.lua\0"
    "UU conflict.lua\0";
  static const char numstat[] =
    "5\t2\tsrc/app.lua\0"
    "1\t0\tsrc/new.lua\0"
    "3\t4\t\0src/old.lua\0src/renamed.lua\0";
  AnvilGitStatusBuildSpec spec = {
    .repository_root = "C:/repo",
    .status_text = status,
    .status_text_len = sizeof(status) - 1,
    .numstat_text = numstat,
    .numstat_text_len = sizeof(numstat) - 1,
    .case_insensitive_paths = true,
  };
  char *error = NULL;
  AnvilGitStatusSnapshot *snapshot = anvil_git_status_snapshot_build(&spec, &error);
  CHECK(snapshot != NULL);
  CHECK(error == NULL);

  AnvilGitStatusLookup lookup;
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "SRC/APP.LUA", strlen("SRC/APP.LUA"), false, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_MODIFIED);
  CHECK(lookup.has_numstat && lookup.additions == 5 && lookup.deletions == 2);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "src", strlen("src"), true, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_ADDED);
  CHECK(lookup.has_numstat && lookup.additions == 9 && lookup.deletions == 6);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "build/cache/object.o", strlen("build/cache/object.o"), false, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_IGNORED);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "scratch/new/note.md", strlen("scratch/new/note.md"), false, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_UNTRACKED);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "src/renamed.lua", strlen("src/renamed.lua"), false, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_RENAMED);
  CHECK(lookup.has_numstat && lookup.additions == 3 && lookup.deletions == 4);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "conflict.lua", strlen("conflict.lua"), false, &lookup));
  CHECK(lookup.kind == ANVIL_GIT_STATUS_UNMERGED);

  AnvilGitStatusSummary summary;
  anvil_git_status_snapshot_summary(snapshot, &summary);
  CHECK(summary.status_records == 6);
  CHECK(summary.numstat_records == 3);
  CHECK(summary.subtree_summaries == 2);
  CHECK(summary.parent_edges > 0);
  CHECK(summary.entry_count >= 7);

  anvil_git_status_snapshot_retain(snapshot);
  anvil_git_status_snapshot_release(snapshot);
  CHECK(anvil_git_status_snapshot_lookup(snapshot, "src/app.lua", strlen("src/app.lua"), false, &lookup));
  anvil_git_status_snapshot_release(snapshot);

  static const char malformed[] =
    " M ../escape.lua\0"
    " M /absolute.lua\0"
    " M safe.lua\0";
  spec.status_text = malformed;
  spec.status_text_len = sizeof(malformed) - 1;
  spec.numstat_text = NULL;
  spec.numstat_text_len = 0;
  snapshot = anvil_git_status_snapshot_build(&spec, &error);
  CHECK(snapshot != NULL);
  anvil_git_status_snapshot_summary(snapshot, &summary);
  CHECK(summary.status_records == 1);
  CHECK(summary.rejected_records == 2);
  CHECK(!anvil_git_status_snapshot_lookup(snapshot, "../escape.lua", strlen("../escape.lua"), false, &lookup));
  anvil_git_status_snapshot_release(snapshot);

  cancel_checks = 0;
  spec.status_text = status;
  spec.status_text_len = sizeof(status) - 1;
  spec.cancelled = cancel_after_first;
  spec.cancel_userdata = NULL;
  snapshot = anvil_git_status_snapshot_build(&spec, &error);
  CHECK(snapshot == NULL);
  CHECK(error && strcmp(error, "cancelled") == 0);
  SDL_free(error);

  SDL_Quit();
  return 0;
}
