#include "project_file_manifest.h"

#include <SDL3/SDL.h>

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#endif

typedef struct ManifestOwnedRecord {
  char *absolute_path;
  char *relative_path;
  AnvilManifestEntryKind kind;
  uint64_t size;
  int64_t modified;
} ManifestOwnedRecord;

struct AnvilProjectFileManifestSnapshot {
  SDL_AtomicInt refcount;
  char *root;
  ManifestOwnedRecord *records;
  uint64_t count;
  uint64_t capacity;
  char *path_arena;
  AnvilProjectFileManifestSummary summary;
};

typedef struct ManifestWalk {
  const AnvilProjectFileManifestBuildSpec *spec;
  AnvilProjectFileManifestSnapshot *snapshot;
  char *error;
} ManifestWalk;

static bool is_cancelled(const AnvilProjectFileManifestBuildSpec *spec) {
  return spec->cancelled && spec->cancelled(spec->cancel_userdata);
}

static void set_error(char **error, const char *message) {
  if (error) *error = SDL_strdup(message ? message : "Project file manifest failed");
}

static bool excluded_name(const char *name) {
  return strcmp(name, ".git") == 0 || strcmp(name, ".obsidian") == 0 ||
    strcmp(name, ".run-meson-tests") == 0;
}

static bool path_has_excluded_component(const char *root, const char *path) {
  const char *relative = path + strlen(root);
  while (*relative == '/' || *relative == '\\') relative++;
  while (*relative) {
    const char *end = relative; while (*end && *end != '/' && *end != '\\') end++;
    size_t length = (size_t)(end - relative);
    if ((length == 4 && strncmp(relative, ".git", 4) == 0)
        || (length == 9 && strncmp(relative, ".obsidian", 9) == 0)
        || (length == 16 && strncmp(relative, ".run-meson-tests", 16) == 0)) return true;
    relative = end; while (*relative == '/' || *relative == '\\') relative++;
  }
  return false;
}

static bool directory_is_link(const char *path) {
#ifdef _WIN32
  int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0); if (!length) return true;
  WCHAR *wide = (WCHAR *)SDL_malloc((size_t)length * sizeof(WCHAR)); if (!wide) return true;
  if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, length)) { SDL_free(wide); return true; }
  DWORD attributes = GetFileAttributesW(wide); SDL_free(wide);
  return attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
#else
  struct stat info; return lstat(path, &info) != 0 || S_ISLNK(info.st_mode);
#endif
}

static const char *extension(const char *path) {
  const char *base = path;
  const char *dot = NULL;
  for (const char *cursor = path; *cursor; cursor++) {
    if (*cursor == '/' || *cursor == '\\') { base = cursor + 1; dot = NULL; }
    else if (*cursor == '.') dot = cursor;
  }
  return dot && dot > base ? dot + 1 : "";
}

static bool ext_equal(const char *value, const char *expected) {
  while (*value && *expected) {
    char left = *value++, right = *expected++;
    if (left >= 'A' && left <= 'Z') left = (char)(left + 32);
    if (right >= 'A' && right <= 'Z') right = (char)(right + 32);
    if (left != right) return false;
  }
  return !*value && !*expected;
}

static bool markdown_extension(const char *ext) {
  return ext_equal(ext, "md") || ext_equal(ext, "markdown") || ext_equal(ext, "mdown");
}

static bool attachment_extension(const char *ext) {
  static const char *extensions[] = {
    "3gp", "avif", "base", "bmp", "canvas", "gif", "jpeg", "jpg", "m4a", "mkv",
    "png", "svg", "webp", "mp3", "wav", "flac", "ogg", "mp4", "webm", "mov",
    "ogv", "pdf",
  };
  for (size_t i = 0; i < sizeof(extensions) / sizeof(extensions[0]); i++)
    if (ext_equal(ext, extensions[i])) return true;
  return false;
}

static bool add_record(ManifestWalk *walk, const char *path, const SDL_PathInfo *info,
  AnvilManifestEntryKind kind) {
  AnvilProjectFileManifestSnapshot *snapshot = walk->snapshot;
  if (snapshot->count >= UINT32_MAX) { walk->error = SDL_strdup("Project manifest record limit exceeded"); return false; }
  if (snapshot->count == snapshot->capacity) {
    uint64_t next = snapshot->capacity ? snapshot->capacity * 2 : 256;
    if (next < snapshot->capacity || next > SIZE_MAX / sizeof(*snapshot->records)) {
      walk->error = SDL_strdup("Project manifest record table overflow");
      return false;
    }
    ManifestOwnedRecord *grown = (ManifestOwnedRecord *)SDL_realloc(snapshot->records,
      (size_t)next * sizeof(*snapshot->records));
    if (!grown) { walk->error = SDL_strdup("out of memory growing Project manifest"); return false; }
    snapshot->records = grown;
    snapshot->capacity = next;
  }
  size_t root_len = strlen(snapshot->root);
  const char *relative = path + root_len;
  while (*relative == '/' || *relative == '\\') relative++;
  ManifestOwnedRecord *record = &snapshot->records[snapshot->count];
  SDL_memset(record, 0, sizeof(*record));
  record->absolute_path = SDL_strdup(path);
  record->relative_path = SDL_strdup(relative);
  record->kind = kind;
  record->size = info ? info->size : 0;
  record->modified = info ? info->modify_time : 0;
  if (!record->absolute_path || !record->relative_path) {
    SDL_free(record->absolute_path); SDL_free(record->relative_path);
    walk->error = SDL_strdup("out of memory copying Project manifest path");
    return false;
  }
  for (char *cursor = record->relative_path; *cursor; cursor++) {
    if (*cursor == '\\') *cursor = '/';
  }
  snapshot->count++;
  if (kind == ANVIL_MANIFEST_DIRECTORY) snapshot->summary.directories++;
  else {
    snapshot->summary.files++;
    snapshot->summary.total_bytes += record->size;
    if (kind == ANVIL_MANIFEST_MARKDOWN) snapshot->summary.markdown_files++;
    else if (kind == ANVIL_MANIFEST_ATTACHMENT) snapshot->summary.attachments++;
    else snapshot->summary.other_files++;
  }
  return true;
}

static SDL_EnumerationResult SDLCALL walk_callback(void *userdata, const char *dirname, const char *fname) {
  ManifestWalk *walk = (ManifestWalk *)userdata;
  if (is_cancelled(walk->spec)) return SDL_ENUM_SUCCESS;
  if (excluded_name(fname)) return SDL_ENUM_CONTINUE;
  size_t dir_len = strlen(dirname), name_len = strlen(fname);
  if (dir_len > SIZE_MAX - name_len - 1) { walk->error = SDL_strdup("Project manifest path overflow"); return SDL_ENUM_FAILURE; }
  char *path = (char *)SDL_malloc(dir_len + name_len + 1);
  if (!path) { walk->error = SDL_strdup("out of memory joining Project manifest path"); return SDL_ENUM_FAILURE; }
  memcpy(path, dirname, dir_len);
  memcpy(path + dir_len, fname, name_len + 1);
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(path, &info)) {
    walk->snapshot->summary.inaccessible_entries++;
    SDL_free(path);
    return SDL_ENUM_CONTINUE;
  }
  bool ok = true;
  if (info.type == SDL_PATHTYPE_DIRECTORY) {
    ok = add_record(walk, path, &info, ANVIL_MANIFEST_DIRECTORY);
    if (ok && !is_cancelled(walk->spec) && !directory_is_link(path)) {
      bool enumerated = SDL_EnumerateDirectory(path, walk_callback, walk);
      if (!enumerated && !walk->error) walk->snapshot->summary.inaccessible_entries++;
    }
  } else if (info.type == SDL_PATHTYPE_FILE) {
    const char *ext = extension(path);
    AnvilManifestEntryKind kind = markdown_extension(ext) ? ANVIL_MANIFEST_MARKDOWN :
      (attachment_extension(ext) || walk->spec->show_unsupported_files
        ? ANVIL_MANIFEST_ATTACHMENT : ANVIL_MANIFEST_OTHER_FILE);
    ok = add_record(walk, path, &info, kind);
  }
  SDL_free(path);
  return ok ? SDL_ENUM_CONTINUE : SDL_ENUM_FAILURE;
}

static int record_compare(const void *left, const void *right) {
  const ManifestOwnedRecord *a = (const ManifestOwnedRecord *)left;
  const ManifestOwnedRecord *b = (const ManifestOwnedRecord *)right;
  return strcmp(a->relative_path, b->relative_path);
}

static bool path_equal(const char *a, const char *b) {
  while (*a && *b) {
    char left = *a == '\\' ? '/' : *a, right = *b == '\\' ? '/' : *b;
#ifdef _WIN32
    if (left >= 'A' && left <= 'Z') left = (char)(left + 32);
    if (right >= 'A' && right <= 'Z') right = (char)(right + 32);
#endif
    if (left != right) return false;
    a++; b++;
  }
  return !*a && !*b;
}

static bool path_has_parent_component(const char *path) {
  if (!path) return false;
  while (*path) {
    while (*path == '/' || *path == '\\') path++;
    const char *segment = path;
    while (*path && *path != '/' && *path != '\\') path++;
    if (path - segment == 2 && segment[0] == '.' && segment[1] == '.') return true;
  }
  return false;
}

static bool path_within(const char *path, const char *scope) {
  if (!path || !scope) return false;
  size_t length = strlen(scope);
  while (length && (scope[length - 1] == '/' || scope[length - 1] == '\\')) length--;
  if (strlen(path) < length) return false;
  for (size_t i = 0; i < length; i++) {
    char left = path[i] == '\\' ? '/' : path[i], right = scope[i] == '\\' ? '/' : scope[i];
#ifdef _WIN32
    if (left >= 'A' && left <= 'Z') left = (char)(left + 32);
    if (right >= 'A' && right <= 'Z') right = (char)(right + 32);
#endif
    if (!path[i] || left != right) return false;
  }
  return !path[length] || path[length] == '/' || path[length] == '\\';
}

static bool record_in_scopes(const char *path, const char *const *paths, uint32_t count) {
  for (uint32_t i = 0; i < count; i++) if (paths[i] && path_within(path, paths[i])) return true;
  return false;
}

static bool copy_previous_record(ManifestWalk *walk, const ManifestOwnedRecord *source) {
  SDL_PathInfo info; SDL_memset(&info, 0, sizeof(info)); info.size = source->size; info.modify_time = source->modified;
  info.type = source->kind == ANVIL_MANIFEST_DIRECTORY ? SDL_PATHTYPE_DIRECTORY : SDL_PATHTYPE_FILE;
  return add_record(walk, source->absolute_path, &info, source->kind);
}

static bool scan_scope(ManifestWalk *walk, const char *path) {
  if (!path || !path_within(path, walk->snapshot->root)) return true;
  if (path_has_excluded_component(walk->snapshot->root, path)) return true;
  SDL_PathInfo info; if (!SDL_GetPathInfo(path, &info)) return true;
  if (info.type == SDL_PATHTYPE_DIRECTORY) {
    if (!path_equal(path, walk->snapshot->root) && !add_record(walk, path, &info, ANVIL_MANIFEST_DIRECTORY)) return false;
    if (directory_is_link(path)) return true;
    if (!SDL_EnumerateDirectory(path, walk_callback, walk)) {
      if (walk->error) return false;
      walk->snapshot->summary.inaccessible_entries++;
    }
    return true;
  }
  if (info.type == SDL_PATHTYPE_FILE) {
    const char *ext = extension(path);
    AnvilManifestEntryKind kind = markdown_extension(ext) ? ANVIL_MANIFEST_MARKDOWN :
      (attachment_extension(ext) || walk->spec->show_unsupported_files ? ANVIL_MANIFEST_ATTACHMENT : ANVIL_MANIFEST_OTHER_FILE);
    return add_record(walk, path, &info, kind);
  }
  return true;
}

static void deduplicate_and_recount(AnvilProjectFileManifestSnapshot *snapshot) {
  uint64_t inaccessible = snapshot->summary.inaccessible_entries;
  uint64_t write = 0;
  for (uint64_t read = 0; read < snapshot->count; read++) {
    if (write && strcmp(snapshot->records[write - 1].relative_path, snapshot->records[read].relative_path) == 0) {
      SDL_free(snapshot->records[read].absolute_path); SDL_free(snapshot->records[read].relative_path); continue;
    }
    if (write != read) snapshot->records[write] = snapshot->records[read];
    write++;
  }
  snapshot->count = write; SDL_memset(&snapshot->summary, 0, sizeof(snapshot->summary));
  snapshot->summary.inaccessible_entries = inaccessible;
  for (uint64_t i = 0; i < snapshot->count; i++) {
    ManifestOwnedRecord *record = &snapshot->records[i];
    if (record->kind == ANVIL_MANIFEST_DIRECTORY) snapshot->summary.directories++;
    else { snapshot->summary.files++; snapshot->summary.total_bytes += record->size;
      if (record->kind == ANVIL_MANIFEST_MARKDOWN) snapshot->summary.markdown_files++;
      else if (record->kind == ANVIL_MANIFEST_ATTACHMENT) snapshot->summary.attachments++;
      else snapshot->summary.other_files++; }
  }
}

static bool compact_paths(AnvilProjectFileManifestSnapshot *snapshot) {
  size_t bytes = 0;
  for (uint64_t i = 0; i < snapshot->count; i++) {
    size_t a = strlen(snapshot->records[i].absolute_path) + 1;
    size_t r = strlen(snapshot->records[i].relative_path) + 1;
    if (a > SIZE_MAX - bytes || r > SIZE_MAX - bytes - a) return false;
    bytes += a + r;
  }
  char *arena = bytes ? (char *)SDL_malloc(bytes) : NULL;
  if (bytes && !arena) return false;
  size_t offset = 0;
  for (uint64_t i = 0; i < snapshot->count; i++) {
    ManifestOwnedRecord *record = &snapshot->records[i];
    size_t len = strlen(record->absolute_path) + 1;
    memcpy(arena + offset, record->absolute_path, len);
    SDL_free(record->absolute_path); record->absolute_path = arena + offset; offset += len;
    len = strlen(record->relative_path) + 1;
    memcpy(arena + offset, record->relative_path, len);
    SDL_free(record->relative_path); record->relative_path = arena + offset; offset += len;
  }
  snapshot->path_arena = arena;
  return true;
}

AnvilProjectFileManifestSnapshot *anvil_project_file_manifest_build(
  const AnvilProjectFileManifestBuildSpec *spec, char **error) {
  if (error) *error = NULL;
  if (!spec || !spec->root || !spec->root[0]) { set_error(error, "Project manifest requires a root"); return NULL; }
  if (path_has_parent_component(spec->root)) {
    set_error(error, "Project manifest root contains parent traversal"); return NULL;
  }
  for (uint32_t i = 0; i < spec->scan_path_count; i++) {
    if (!spec->scan_paths || !spec->scan_paths[i]
        || path_has_parent_component(spec->scan_paths[i])
        || !path_within(spec->scan_paths[i], spec->root)) {
      set_error(error, "Project manifest scan path is outside its root"); return NULL;
    }
  }
  for (uint32_t i = 0; i < spec->remove_path_count; i++) {
    if (!spec->remove_paths || !spec->remove_paths[i]
        || path_has_parent_component(spec->remove_paths[i])
        || !path_within(spec->remove_paths[i], spec->root)) {
      set_error(error, "Project manifest removal path is outside its root"); return NULL;
    }
  }
  if (is_cancelled(spec)) { set_error(error, "cancelled"); return NULL; }
  Uint64 started = SDL_GetTicksNS();
  AnvilProjectFileManifestSnapshot *snapshot = (AnvilProjectFileManifestSnapshot *)SDL_calloc(1, sizeof(*snapshot));
  if (!snapshot) { set_error(error, "out of memory allocating Project manifest"); return NULL; }
  SDL_SetAtomicInt(&snapshot->refcount, 1);
  snapshot->root = SDL_strdup(spec->root);
  ManifestWalk walk = { spec, snapshot, NULL };
  bool scoped = spec->scoped && spec->previous && spec->scan_path_count > 0;
  for (uint32_t i = 0; scoped && i < spec->scan_path_count; i++) {
    if (spec->scan_paths[i] && path_equal(spec->scan_paths[i], snapshot->root)) scoped = false;
  }
  bool ok = snapshot->root != NULL;
  if (ok && scoped) {
    for (uint64_t i = 0; ok && i < spec->previous->count; i++) {
      if ((i & 255u) == 0 && is_cancelled(spec)) { ok = false; break; }
      const ManifestOwnedRecord *record = &spec->previous->records[i];
      if (!record_in_scopes(record->absolute_path, spec->scan_paths, spec->scan_path_count)
          && !record_in_scopes(record->absolute_path, spec->remove_paths, spec->remove_path_count))
        ok = copy_previous_record(&walk, record);
    }
    for (uint32_t i = 0; ok && i < spec->scan_path_count; i++) {
      if (is_cancelled(spec)) { ok = false; break; }
      ok = scan_scope(&walk, spec->scan_paths[i]);
    }
  } else if (ok) {
    ok = SDL_EnumerateDirectory(snapshot->root, walk_callback, &walk);
  }
  if (is_cancelled(spec)) { SDL_free(walk.error); walk.error = SDL_strdup("cancelled"); ok = false; }
  if (ok && snapshot->count > 1) qsort(snapshot->records, (size_t)snapshot->count, sizeof(*snapshot->records), record_compare);
  if (ok) deduplicate_and_recount(snapshot);
  if (ok) ok = compact_paths(snapshot);
  if (!ok) {
    set_error(error, walk.error ? walk.error : (SDL_GetError()[0] ? SDL_GetError() : "Project manifest scan failed"));
    SDL_free(walk.error);
    anvil_project_file_manifest_release(snapshot);
    return NULL;
  }
  SDL_free(walk.error);
  snapshot->summary.records = snapshot->count;
  snapshot->summary.scan_ms = (double)(SDL_GetTicksNS() - started) / 1000000.0;
  return snapshot;
}

void anvil_project_file_manifest_retain(AnvilProjectFileManifestSnapshot *snapshot) {
  if (snapshot) SDL_AddAtomicInt(&snapshot->refcount, 1);
}

void anvil_project_file_manifest_release(AnvilProjectFileManifestSnapshot *snapshot) {
  if (!snapshot || SDL_AddAtomicInt(&snapshot->refcount, -1) != 1) return;
  if (!snapshot->path_arena) {
    for (uint64_t i = 0; i < snapshot->count; i++) {
      SDL_free(snapshot->records[i].absolute_path); SDL_free(snapshot->records[i].relative_path);
    }
  }
  SDL_free(snapshot->path_arena);
  SDL_free(snapshot->records);
  SDL_free(snapshot->root);
  SDL_free(snapshot);
}

void anvil_project_file_manifest_summary(const AnvilProjectFileManifestSnapshot *snapshot,
  AnvilProjectFileManifestSummary *summary) {
  if (!summary) return;
  if (snapshot) *summary = snapshot->summary; else SDL_memset(summary, 0, sizeof(*summary));
}

uint64_t anvil_project_file_manifest_count(const AnvilProjectFileManifestSnapshot *snapshot) {
  return snapshot ? snapshot->count : 0;
}

static bool record_view(const ManifestOwnedRecord *owned, AnvilProjectFileManifestRecord *record) {
  if (!owned || !record) return false;
  record->absolute_path = owned->absolute_path;
  record->relative_path = owned->relative_path;
  record->kind = owned->kind;
  record->size = owned->size;
  record->modified = owned->modified;
  return true;
}

bool anvil_project_file_manifest_record_at(const AnvilProjectFileManifestSnapshot *snapshot,
  uint64_t index, AnvilProjectFileManifestRecord *record) {
  return snapshot && index < snapshot->count && record_view(&snapshot->records[index], record);
}

bool anvil_project_file_manifest_lookup(const AnvilProjectFileManifestSnapshot *snapshot,
  const char *relative_path, AnvilProjectFileManifestRecord *record) {
  if (!snapshot || !relative_path) return false;
  uint64_t low = 0, high = snapshot->count;
  while (low < high) {
    uint64_t middle = low + (high - low) / 2;
    int cmp = strcmp(snapshot->records[middle].relative_path, relative_path);
    if (cmp < 0) low = middle + 1; else high = middle;
  }
  return low < snapshot->count && strcmp(snapshot->records[low].relative_path, relative_path) == 0 &&
    record_view(&snapshot->records[low], record);
}

const char *anvil_manifest_entry_kind_name(AnvilManifestEntryKind kind) {
  switch (kind) {
    case ANVIL_MANIFEST_DIRECTORY: return "directory";
    case ANVIL_MANIFEST_MARKDOWN: return "markdown";
    case ANVIL_MANIFEST_ATTACHMENT: return "attachment";
    case ANVIL_MANIFEST_OTHER_FILE: return "other";
    default: return "unknown";
  }
}
