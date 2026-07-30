#include "project_file_manifest.h"

#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)

static bool write_file(const char *path, const char *text) {
  FILE *file = fopen(path, "wb");
  if (!file) return false;
  bool ok = fwrite(text, 1, strlen(text), file) == strlen(text);
  fclose(file);
  return ok;
}

static bool always_cancel(void *userdata) { (void)userdata; return true; }

int main(void) {
  CHECK(SDL_Init(0));
  char root[512];
  SDL_snprintf(root, sizeof(root), "manifest-test-%llu", (unsigned long long)SDL_GetTicksNS());
  CHECK(SDL_CreateDirectory(root));
  char notes[600], git[600], nested[700], path[800];
  SDL_snprintf(notes, sizeof(notes), "%s/notes", root);
  SDL_snprintf(git, sizeof(git), "%s/.git", root);
  SDL_snprintf(nested, sizeof(nested), "%s/nested", notes);
  CHECK(SDL_CreateDirectory(notes));
  CHECK(SDL_CreateDirectory(nested));
  CHECK(SDL_CreateDirectory(git));
  SDL_snprintf(path, sizeof(path), "%s/a.md", notes); CHECK(write_file(path, "# A\n"));
  SDL_snprintf(path, sizeof(path), "%s/b.markdown", nested); CHECK(write_file(path, "# B\n"));
  SDL_snprintf(path, sizeof(path), "%s/image.png", root); CHECK(write_file(path, "png"));
  SDL_snprintf(path, sizeof(path), "%s/plain.txt", root); CHECK(write_file(path, "text"));
  SDL_snprintf(path, sizeof(path), "%s/ignored.md", git); CHECK(write_file(path, "ignored"));

  AnvilProjectFileManifestBuildSpec spec = { .root = root };
  char *error = NULL;
  AnvilProjectFileManifestSnapshot *snapshot = anvil_project_file_manifest_build(&spec, &error);
  CHECK(snapshot != NULL && error == NULL);
  AnvilProjectFileManifestSummary summary;
  anvil_project_file_manifest_summary(snapshot, &summary);
  CHECK(summary.markdown_files == 2);
  CHECK(summary.attachments == 1);
  CHECK(summary.other_files == 1);
  CHECK(summary.directories == 2);
  CHECK(summary.records == 6);

  AnvilProjectFileManifestRecord record;
  CHECK(anvil_project_file_manifest_lookup(snapshot, "notes/a.md", &record));
  CHECK(record.kind == ANVIL_MANIFEST_MARKDOWN);
  CHECK(anvil_project_file_manifest_lookup(snapshot, "image.png", &record));
  CHECK(record.kind == ANVIL_MANIFEST_ATTACHMENT);
  CHECK(!anvil_project_file_manifest_lookup(snapshot, ".git/ignored.md", &record));
  const char *previous = "";
  for (uint64_t i = 0; i < anvil_project_file_manifest_count(snapshot); i++) {
    CHECK(anvil_project_file_manifest_record_at(snapshot, i, &record));
    CHECK(strcmp(previous, record.relative_path) < 0);
    previous = record.relative_path;
  }
  char removed_path[800], added_path[800];
  SDL_snprintf(removed_path, sizeof(removed_path), "%s/a.md", notes); CHECK(SDL_RemovePath(removed_path));
  SDL_snprintf(added_path, sizeof(added_path), "%s/c.md", notes); CHECK(write_file(added_path, "# C\n"));
  char outside_path[800]; SDL_snprintf(outside_path, sizeof(outside_path), "%s/image.png", root); CHECK(SDL_RemovePath(outside_path));
  char obsidian[800], excluded_path[800]; SDL_snprintf(obsidian, sizeof(obsidian), "%s/.obsidian", root); CHECK(SDL_CreateDirectory(obsidian));
  SDL_snprintf(excluded_path, sizeof(excluded_path), "%s/Hidden.md", obsidian); CHECK(write_file(excluded_path, "# Hidden\n"));
  const char *scopes[] = { notes, obsidian };
  AnvilProjectFileManifestBuildSpec scoped_spec = {
    .root = root, .previous = snapshot, .scan_paths = scopes, .scan_path_count = 2, .scoped = true,
  };
  AnvilProjectFileManifestSnapshot *scoped = anvil_project_file_manifest_build(&scoped_spec, &error);
  CHECK(scoped != NULL);
  CHECK(!anvil_project_file_manifest_lookup(scoped, "notes/a.md", &record));
  CHECK(anvil_project_file_manifest_lookup(scoped, "notes/c.md", &record));
  CHECK(anvil_project_file_manifest_lookup(scoped, "notes/nested/b.markdown", &record));
  CHECK(anvil_project_file_manifest_lookup(scoped, "image.png", &record));
  CHECK(!anvil_project_file_manifest_lookup(scoped, ".obsidian/Hidden.md", &record));
  anvil_project_file_manifest_release(scoped);
  anvil_project_file_manifest_release(snapshot);

  spec.show_unsupported_files = true;
  snapshot = anvil_project_file_manifest_build(&spec, &error);
  CHECK(snapshot != NULL);
  CHECK(anvil_project_file_manifest_lookup(snapshot, "plain.txt", &record));
  CHECK(record.kind == ANVIL_MANIFEST_ATTACHMENT);
  anvil_project_file_manifest_release(snapshot);

  spec.cancelled = always_cancel;
  snapshot = anvil_project_file_manifest_build(&spec, &error);
  CHECK(snapshot == NULL && error && strcmp(error, "cancelled") == 0);
  SDL_free(error);

  SDL_snprintf(path, sizeof(path), "%s/ignored.md", git); SDL_RemovePath(path);
  SDL_snprintf(path, sizeof(path), "%s/b.markdown", nested); SDL_RemovePath(path);
  SDL_RemovePath(added_path);
  SDL_RemovePath(excluded_path); SDL_RemovePath(obsidian);
  SDL_snprintf(path, sizeof(path), "%s/image.png", root); SDL_RemovePath(path);
  SDL_snprintf(path, sizeof(path), "%s/plain.txt", root); SDL_RemovePath(path);
  SDL_RemovePath(nested); SDL_RemovePath(notes); SDL_RemovePath(git); SDL_RemovePath(root);
  SDL_Quit();
  return 0;
}
