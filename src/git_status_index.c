#include "git_status_index.h"

#include <SDL3/SDL.h>

#include <limits.h>
#include <string.h>

#define INITIAL_CAPACITY 64u
#define LOAD_NUMERATOR 7u
#define LOAD_DENOMINATOR 10u

typedef struct GitEntry {
  char *path;
  uint32_t path_len;
  uint64_t hash;
  AnvilGitStatusKind exact_kind;
  AnvilGitStatusKind directory_kind;
  AnvilGitStatusKind subtree_kind;
  uint64_t additions;
  uint64_t deletions;
  uint64_t directory_additions;
  uint64_t directory_deletions;
  bool has_numstat;
  bool has_directory_numstat;
} GitEntry;

struct AnvilGitStatusSnapshot {
  SDL_AtomicInt refcount;
  char *repository_root;
  bool case_insensitive_paths;
  GitEntry *entries;
  uint32_t capacity;
  uint32_t count;
  AnvilGitStatusSummary summary;
};

typedef struct FieldCursor {
  const char *text;
  size_t len;
  size_t offset;
} FieldCursor;

static void set_error(char **error, const char *message) {
  if (error) *error = SDL_strdup(message ? message : "git status index failed");
}

static bool cancelled(const AnvilGitStatusBuildSpec *spec) {
  return spec->cancelled && spec->cancelled(spec->cancel_userdata);
}

static uint64_t hash_bytes(const char *text, size_t len) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (size_t i = 0; i < len; i++) {
    hash ^= (unsigned char)text[i];
    hash *= UINT64_C(1099511628211);
  }
  return hash ? hash : 1;
}

static int kind_rank(AnvilGitStatusKind kind) {
  switch (kind) {
    case ANVIL_GIT_STATUS_DELETED: return 7;
    case ANVIL_GIT_STATUS_ADDED: return 6;
    case ANVIL_GIT_STATUS_MODIFIED:
    case ANVIL_GIT_STATUS_RENAMED:
    case ANVIL_GIT_STATUS_COPIED:
    case ANVIL_GIT_STATUS_TYPECHANGE:
    case ANVIL_GIT_STATUS_UNMERGED: return 5;
    case ANVIL_GIT_STATUS_UNTRACKED: return 2;
    case ANVIL_GIT_STATUS_IGNORED: return 1;
    default: return 0;
  }
}

static AnvilGitStatusKind stronger(AnvilGitStatusKind current, AnvilGitStatusKind candidate) {
  return kind_rank(candidate) > kind_rank(current) ? candidate : current;
}

const char *anvil_git_status_kind_name(AnvilGitStatusKind kind) {
  switch (kind) {
    case ANVIL_GIT_STATUS_IGNORED: return "ignored";
    case ANVIL_GIT_STATUS_UNTRACKED: return "untracked";
    case ANVIL_GIT_STATUS_MODIFIED: return "modified";
    case ANVIL_GIT_STATUS_RENAMED: return "renamed";
    case ANVIL_GIT_STATUS_COPIED: return "copied";
    case ANVIL_GIT_STATUS_TYPECHANGE: return "typechange";
    case ANVIL_GIT_STATUS_UNMERGED: return "unmerged";
    case ANVIL_GIT_STATUS_ADDED: return "added";
    case ANVIL_GIT_STATUS_DELETED: return "deleted";
    default: return NULL;
  }
}

static AnvilGitStatusKind status_kind(const char *xy) {
  if (xy[0] == '!' && xy[1] == '!') return ANVIL_GIT_STATUS_IGNORED;
  if (xy[0] == '?' && xy[1] == '?') return ANVIL_GIT_STATUS_UNTRACKED;
  if ((xy[0] == 'D' && xy[1] == 'D') || (xy[0] == 'A' && xy[1] == 'U') ||
      (xy[0] == 'U' && xy[1] == 'D') || (xy[0] == 'U' && xy[1] == 'A') ||
      (xy[0] == 'D' && xy[1] == 'U') || (xy[0] == 'A' && xy[1] == 'A') ||
      (xy[0] == 'U' && xy[1] == 'U') || xy[0] == 'U' || xy[1] == 'U')
    return ANVIL_GIT_STATUS_UNMERGED;
  if (xy[0] == 'R' || xy[1] == 'R') return ANVIL_GIT_STATUS_RENAMED;
  if (xy[0] == 'C' || xy[1] == 'C') return ANVIL_GIT_STATUS_COPIED;
  if (xy[0] == 'D' || xy[1] == 'D') return ANVIL_GIT_STATUS_DELETED;
  if (xy[0] == 'A' || xy[1] == 'A') return ANVIL_GIT_STATUS_ADDED;
  if (xy[0] == 'T' || xy[1] == 'T') return ANVIL_GIT_STATUS_TYPECHANGE;
  if (xy[0] == 'M' || xy[1] == 'M') return ANVIL_GIT_STATUS_MODIFIED;
  return ANVIL_GIT_STATUS_NONE;
}

static bool next_field(FieldCursor *cursor, const char **field, size_t *field_len) {
  if (!cursor || cursor->offset >= cursor->len) return false;
  size_t start = cursor->offset;
  while (cursor->offset < cursor->len && cursor->text[cursor->offset] != '\0') cursor->offset++;
  *field = cursor->text + start;
  *field_len = cursor->offset - start;
  if (cursor->offset < cursor->len) cursor->offset++;
  return true;
}

static char ascii_fold(char value) {
  return value >= 'A' && value <= 'Z' ? (char)(value + ('a' - 'A')) : value;
}

static char *canonical_path(const char *path, size_t len, bool insensitive, size_t *out_len, bool *directory) {
  if (directory) *directory = false;
  while (len >= 2 && path[0] == '.' && (path[1] == '/' || path[1] == '\\')) { path += 2; len -= 2; }
  while (len && (path[len - 1] == '/' || path[len - 1] == '\\')) {
    if (directory) *directory = true;
    len--;
  }
  if (!len || path[0] == '/' || path[0] == '\\' ||
      (len >= 3 && ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) &&
       path[1] == ':' && (path[2] == '/' || path[2] == '\\'))) return NULL;

  char *result = (char *)SDL_malloc(len + 1);
  if (!result) return NULL;
  size_t written = 0, segment_start = 0;
  for (size_t i = 0; i <= len; i++) {
    bool separator = i == len || path[i] == '/' || path[i] == '\\';
    if (!separator) continue;
    size_t segment_len = i - segment_start;
    if (!segment_len || (segment_len == 2 && path[segment_start] == '.' && path[segment_start + 1] == '.')) {
      SDL_free(result);
      return NULL;
    }
    if (!(segment_len == 1 && path[segment_start] == '.')) {
      if (written) result[written++] = '/';
      for (size_t j = segment_start; j < i; j++)
        result[written++] = insensitive ? ascii_fold(path[j]) : path[j];
    }
    segment_start = i + 1;
  }
  if (!written) { SDL_free(result); return NULL; }
  result[written] = '\0';
  if (out_len) *out_len = written;
  return result;
}

static bool grow(AnvilGitStatusSnapshot *snapshot, uint32_t capacity) {
  GitEntry *old_entries = snapshot->entries;
  uint32_t old_capacity = snapshot->capacity;
  GitEntry *entries = (GitEntry *)SDL_calloc(capacity, sizeof(*entries));
  if (!entries) return false;
  snapshot->entries = entries;
  snapshot->capacity = capacity;
  snapshot->count = 0;
  for (uint32_t i = 0; i < old_capacity; i++) {
    GitEntry old = old_entries[i];
    if (!old.path) continue;
    uint32_t slot = (uint32_t)(old.hash & (capacity - 1));
    while (entries[slot].path) slot = (slot + 1) & (capacity - 1);
    entries[slot] = old;
    snapshot->count++;
  }
  SDL_free(old_entries);
  return true;
}

static GitEntry *entry_for(AnvilGitStatusSnapshot *snapshot, const char *path, size_t len, bool create) {
  if (!snapshot->capacity && !grow(snapshot, INITIAL_CAPACITY)) return NULL;
  if (create && (snapshot->count + 1) * LOAD_DENOMINATOR >= snapshot->capacity * LOAD_NUMERATOR) {
    if (snapshot->capacity > UINT32_MAX / 2 || !grow(snapshot, snapshot->capacity * 2)) return NULL;
  }
  uint64_t hash = hash_bytes(path, len);
  uint32_t slot = (uint32_t)(hash & (snapshot->capacity - 1));
  while (snapshot->entries[slot].path) {
    GitEntry *entry = &snapshot->entries[slot];
    if (entry->hash == hash && entry->path_len == len && memcmp(entry->path, path, len) == 0) return entry;
    slot = (slot + 1) & (snapshot->capacity - 1);
  }
  if (!create) return NULL;
  GitEntry *entry = &snapshot->entries[slot];
  entry->path = (char *)SDL_malloc(len + 1);
  if (!entry->path) return NULL;
  memcpy(entry->path, path, len);
  entry->path[len] = '\0';
  entry->path_len = (uint32_t)len;
  entry->hash = hash;
  snapshot->count++;
  return entry;
}

static bool update_parents(AnvilGitStatusSnapshot *snapshot, char *path, size_t len,
  AnvilGitStatusKind kind, bool numstat, uint64_t additions, uint64_t deletions) {
  for (size_t i = len; i > 0; i--) {
    if (path[i - 1] != '/') continue;
    GitEntry *entry = entry_for(snapshot, path, i - 1, true);
    if (!entry) return false;
    if (numstat) {
      entry->has_directory_numstat = true;
      entry->directory_additions += additions;
      entry->directory_deletions += deletions;
    } else {
      entry->directory_kind = stronger(entry->directory_kind, kind);
    }
    snapshot->summary.parent_edges++;
  }
  return true;
}

static bool parse_uint(const char *text, size_t len, uint64_t *value) {
  if (!len) return false;
  uint64_t total = 0;
  for (size_t i = 0; i < len; i++) {
    if (text[i] < '0' || text[i] > '9') return false;
    uint64_t digit = (uint64_t)(text[i] - '0');
    if (total > (UINT64_MAX - digit) / 10) return false;
    total = total * 10 + digit;
  }
  *value = total;
  return true;
}

static bool parse_status(AnvilGitStatusSnapshot *snapshot, const AnvilGitStatusBuildSpec *spec, char **error) {
  FieldCursor cursor = { spec->status_text, spec->status_text_len, 0 };
  const char *field;
  size_t len;
  while (next_field(&cursor, &field, &len)) {
    if (cancelled(spec)) { set_error(error, "cancelled"); return false; }
    if (!len) continue;
    AnvilGitStatusKind kind = len >= 2 ? status_kind(field) : ANVIL_GIT_STATUS_NONE;
    const char *raw_path = len >= 3 ? field + 3 : NULL;
    size_t raw_len = len >= 3 ? len - 3 : 0;
    if (kind == ANVIL_GIT_STATUS_RENAMED || kind == ANVIL_GIT_STATUS_COPIED) {
      const char *ignored_source;
      size_t ignored_len;
      (void)next_field(&cursor, &ignored_source, &ignored_len);
    }
    bool directory = false;
    size_t path_len = 0;
    char *path = raw_path ? canonical_path(raw_path, raw_len, snapshot->case_insensitive_paths, &path_len, &directory) : NULL;
    if (!kind || !path) { snapshot->summary.rejected_records++; SDL_free(path); continue; }
    GitEntry *entry = entry_for(snapshot, path, path_len, true);
    if (!entry) { SDL_free(path); set_error(error, "out of memory"); return false; }
    entry->exact_kind = stronger(entry->exact_kind, kind);
    if (directory && (kind == ANVIL_GIT_STATUS_IGNORED || kind == ANVIL_GIT_STATUS_UNTRACKED)) {
      entry->subtree_kind = stronger(entry->subtree_kind, kind);
      snapshot->summary.subtree_summaries++;
    }
    if (!update_parents(snapshot, path, path_len, kind, false, 0, 0)) {
      SDL_free(path); set_error(error, "out of memory"); return false;
    }
    snapshot->summary.status_records++;
    SDL_free(path);
  }
  return true;
}

static bool parse_numstat(AnvilGitStatusSnapshot *snapshot, const AnvilGitStatusBuildSpec *spec, char **error) {
  FieldCursor cursor = { spec->numstat_text, spec->numstat_text_len, 0 };
  const char *field;
  size_t len;
  while (next_field(&cursor, &field, &len)) {
    if (cancelled(spec)) { set_error(error, "cancelled"); return false; }
    if (!len) continue;
    const char *first_tab = memchr(field, '\t', len);
    const char *second_tab = first_tab ? memchr(first_tab + 1, '\t', len - (size_t)(first_tab + 1 - field)) : NULL;
    if (!first_tab || !second_tab) { snapshot->summary.rejected_records++; continue; }
    uint64_t additions = 0, deletions = 0;
    if (!parse_uint(field, (size_t)(first_tab - field), &additions) ||
        !parse_uint(first_tab + 1, (size_t)(second_tab - first_tab - 1), &deletions)) {
      snapshot->summary.rejected_records++;
      continue;
    }
    const char *raw_path = second_tab + 1;
    size_t raw_len = len - (size_t)(raw_path - field);
    if (!raw_len) {
      const char *old_path;
      size_t old_len;
      if (!next_field(&cursor, &old_path, &old_len) || !next_field(&cursor, &raw_path, &raw_len)) {
        snapshot->summary.rejected_records++;
        continue;
      }
    }
    size_t path_len = 0;
    char *path = canonical_path(raw_path, raw_len, snapshot->case_insensitive_paths, &path_len, NULL);
    if (!path) { snapshot->summary.rejected_records++; continue; }
    GitEntry *entry = entry_for(snapshot, path, path_len, true);
    if (!entry) { SDL_free(path); set_error(error, "out of memory"); return false; }
    entry->has_numstat = true;
    entry->additions = additions;
    entry->deletions = deletions;
    if (!update_parents(snapshot, path, path_len, ANVIL_GIT_STATUS_NONE, true, additions, deletions)) {
      SDL_free(path); set_error(error, "out of memory"); return false;
    }
    snapshot->summary.numstat_records++;
    SDL_free(path);
  }
  return true;
}

AnvilGitStatusSnapshot *anvil_git_status_snapshot_build(const AnvilGitStatusBuildSpec *spec, char **error) {
  if (error) *error = NULL;
  if (!spec || (!spec->status_text && spec->status_text_len) || (!spec->numstat_text && spec->numstat_text_len)) {
    set_error(error, "invalid Git status build specification");
    return NULL;
  }
  if (cancelled(spec)) { set_error(error, "cancelled"); return NULL; }
  Uint64 started = SDL_GetTicksNS();
  AnvilGitStatusSnapshot *snapshot = (AnvilGitStatusSnapshot *)SDL_calloc(1, sizeof(*snapshot));
  if (!snapshot) { set_error(error, "out of memory"); return NULL; }
  SDL_SetAtomicInt(&snapshot->refcount, 1);
  snapshot->repository_root = SDL_strdup(spec->repository_root ? spec->repository_root : "");
  snapshot->case_insensitive_paths = spec->case_insensitive_paths;
  snapshot->summary.status_bytes = spec->status_text_len;
  snapshot->summary.numstat_bytes = spec->numstat_text_len;
  if (!snapshot->repository_root || !grow(snapshot, INITIAL_CAPACITY) ||
      !parse_status(snapshot, spec, error) || !parse_numstat(snapshot, spec, error)) {
    anvil_git_status_snapshot_release(snapshot);
    return NULL;
  }
  snapshot->summary.entry_count = snapshot->count;
  snapshot->summary.build_ms = (double)(SDL_GetTicksNS() - started) / 1000000.0;
  return snapshot;
}

void anvil_git_status_snapshot_retain(AnvilGitStatusSnapshot *snapshot) {
  if (snapshot) SDL_AddAtomicInt(&snapshot->refcount, 1);
}

void anvil_git_status_snapshot_release(AnvilGitStatusSnapshot *snapshot) {
  if (!snapshot || SDL_AddAtomicInt(&snapshot->refcount, -1) != 1) return;
  for (uint32_t i = 0; i < snapshot->capacity; i++) SDL_free(snapshot->entries[i].path);
  SDL_free(snapshot->entries);
  SDL_free(snapshot->repository_root);
  SDL_free(snapshot);
}

void anvil_git_status_snapshot_summary(const AnvilGitStatusSnapshot *snapshot, AnvilGitStatusSummary *summary) {
  if (!summary) return;
  if (snapshot) *summary = snapshot->summary;
  else SDL_memset(summary, 0, sizeof(*summary));
}

bool anvil_git_status_snapshot_lookup(const AnvilGitStatusSnapshot *snapshot, const char *path, size_t path_len,
  bool is_directory, AnvilGitStatusLookup *lookup) {
  if (lookup) SDL_memset(lookup, 0, sizeof(*lookup));
  if (!snapshot || !path || !lookup) return false;
  size_t canonical_len = 0;
  char *canonical = canonical_path(path, path_len, snapshot->case_insensitive_paths, &canonical_len, NULL);
  if (!canonical) return false;
  GitEntry *entry = entry_for((AnvilGitStatusSnapshot *)snapshot, canonical, canonical_len, false);
  AnvilGitStatusKind kind = entry ? entry->exact_kind : ANVIL_GIT_STATUS_NONE;
  if (is_directory && entry) kind = stronger(kind, entry->directory_kind);
  if (entry) kind = stronger(kind, entry->subtree_kind);
  for (size_t i = canonical_len; i > 0; i--) {
    if (canonical[i - 1] != '/') continue;
    GitEntry *parent = entry_for((AnvilGitStatusSnapshot *)snapshot, canonical, i - 1, false);
    if (parent) kind = stronger(kind, parent->subtree_kind);
  }
  lookup->kind = kind;
  if (entry && (is_directory ? entry->has_directory_numstat : entry->has_numstat)) {
    lookup->has_numstat = true;
    lookup->additions = is_directory ? entry->directory_additions : entry->additions;
    lookup->deletions = is_directory ? entry->directory_deletions : entry->deletions;
  }
  SDL_free(canonical);
  return lookup->kind != ANVIL_GIT_STATUS_NONE || lookup->has_numstat;
}
