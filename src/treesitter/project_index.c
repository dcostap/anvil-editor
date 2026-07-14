#include "project_index.h"

#include "../fuzzy.h"

#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>

typedef struct ProjectFileEntry {
  AnvilTSProjectFileResult *file;
  char *fingerprint;
  bool usage_complete;
} ProjectFileEntry;

typedef struct ProjectRecordRef {
  AnvilTSProjectFileResult *file;
  uint32_t index;
} ProjectRecordRef;

typedef struct ProjectUsageNameEntry {
  const char *name;
  uint32_t name_len;
  uint32_t *usage_indices;
  uint32_t usage_count;
  uint32_t usage_capacity;
} ProjectUsageNameEntry;

struct AnvilTSProjectBuilder {
  SDL_AtomicInt refcount;
  uint64_t id;
  SDL_Mutex *mutex;
  ProjectFileEntry *files;
  uint32_t file_count;
  uint32_t file_capacity;
  uint32_t *path_slots;
  uint32_t path_slot_count;
  uint32_t usage_cap;
  bool frozen;
  bool closed;
  bool registered;
  uint64_t version;
  struct AnvilTSProjectBuilder *registry_next;
};

struct AnvilTSProjectSnapshot {
  SDL_AtomicInt refcount;
  char status[16];
  ProjectFileEntry *files;
  uint32_t file_count;
  ProjectRecordRef *symbols;
  uint32_t symbol_count;
  FuzzyIndex symbol_fuzzy;
  ProjectRecordRef *usages;
  uint32_t usage_count;
  ProjectUsageNameEntry *usage_names;
  uint32_t usage_name_count;
  uint32_t usage_name_capacity;
  uint32_t *usage_name_slots;
  uint32_t usage_name_slot_count;
  bool usage_truncated;
  bool usage_complete;
};

static SDL_InitState registry_init;
static SDL_Mutex *registry_mutex;
static AnvilTSProjectBuilder *registry_builders;
static SDL_AtomicInt registry_sequence;

static SDL_Mutex *project_registry_mutex(void) {
  if (SDL_ShouldInit(&registry_init)) {
    registry_mutex = SDL_CreateMutex();
    SDL_SetInitialized(&registry_init, registry_mutex != NULL);
  }
  return registry_mutex;
}

static char *project_strdup(const char *text) {
  if (!text) text = "";
  size_t length = strlen(text);
  if (length == SIZE_MAX) return NULL;
  char *copy = (char *)malloc(length + 1);
  if (copy) memcpy(copy, text, length + 1);
  return copy;
}

static void set_error(char **error, const char *message) {
  if (error && !*error) *error = project_strdup(message ? message : "native Project index operation failed");
}

static bool grow_array(void **items, uint32_t *capacity, uint32_t needed, size_t item_size) {
  if (needed <= *capacity) return true;
  uint32_t next = *capacity ? *capacity : 16;
  while (next < needed) {
    if (next > UINT32_MAX / 2) { next = needed; break; }
    next *= 2;
  }
  if ((size_t)next > SIZE_MAX / item_size) return false;
  void *grown = realloc(*items, (size_t)next * item_size);
  if (!grown) return false;
  *items = grown;
  *capacity = next;
  return true;
}

static uint64_t bytes_hash(const char *text, uint32_t length) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (uint32_t i = 0; i < length; i++) { hash ^= (unsigned char)text[i]; hash *= UINT64_C(1099511628211); }
  return hash ? hash : 1;
}

static uint64_t path_hash(const char *path) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (const unsigned char *cursor = (const unsigned char *)(path ? path : ""); *cursor; cursor++) {
#ifdef _WIN32
    hash ^= (unsigned char)SDL_tolower(*cursor);
#else
    hash ^= *cursor;
#endif
    hash *= UINT64_C(1099511628211);
  }
  return hash ? hash : 1;
}

static bool project_path_equal(const char *left, const char *right) {
#ifdef _WIN32
  return SDL_strcasecmp(left ? left : "", right ? right : "") == 0;
#else
  return strcmp(left ? left : "", right ? right : "") == 0;
#endif
}

static bool rebuild_path_slots(AnvilTSProjectBuilder *builder, uint32_t required_files) {
  if (required_files <= builder->path_slot_count / 2) return true;
  uint32_t slot_count = 16;
  while (slot_count / 2 < required_files) {
    if (slot_count > UINT32_MAX / 2) return false;
    slot_count *= 2;
  }
  uint32_t *slots = (uint32_t *)calloc(slot_count, sizeof(*slots));
  if (!slots) return false;
  for (uint32_t i = 0; i < builder->file_count; i++) {
    const char *path = anvil_ts_project_file_path(builder->files[i].file);
    uint32_t slot = (uint32_t)path_hash(path) & (slot_count - 1);
    while (slots[slot]) slot = (slot + 1) & (slot_count - 1);
    slots[slot] = i + 1;
  }
  free(builder->path_slots);
  builder->path_slots = slots;
  builder->path_slot_count = slot_count;
  return true;
}

static uint32_t builder_file_index(const AnvilTSProjectBuilder *builder, const char *path) {
  if (!builder->path_slot_count) return UINT32_MAX;
  uint32_t slot = (uint32_t)path_hash(path) & (builder->path_slot_count - 1);
  while (builder->path_slots[slot]) {
    uint32_t index = builder->path_slots[slot] - 1;
    const char *existing = anvil_ts_project_file_path(builder->files[index].file);
    if (project_path_equal(existing, path)) return index;
    slot = (slot + 1) & (builder->path_slot_count - 1);
  }
  return UINT32_MAX;
}

static void insert_path_slot(AnvilTSProjectBuilder *builder, uint32_t index) {
  const char *path = anvil_ts_project_file_path(builder->files[index].file);
  uint32_t slot = (uint32_t)path_hash(path) & (builder->path_slot_count - 1);
  while (builder->path_slots[slot]) slot = (slot + 1) & (builder->path_slot_count - 1);
  builder->path_slots[slot] = index + 1;
}

static void release_file_entry(ProjectFileEntry *entry) {
  if (!entry) return;
  anvil_ts_project_file_free(entry->file);
  free(entry->fingerprint);
  memset(entry, 0, sizeof(*entry));
}

void anvil_ts_project_builder_retain(AnvilTSProjectBuilder *builder) {
  if (builder) SDL_AtomicIncRef(&builder->refcount);
}

void anvil_ts_project_builder_release(AnvilTSProjectBuilder *builder) {
  if (!builder || !SDL_AtomicDecRef(&builder->refcount)) return;
  for (uint32_t i = 0; i < builder->file_count; i++) release_file_entry(&builder->files[i]);
  free(builder->files);
  free(builder->path_slots);
  SDL_DestroyMutex(builder->mutex);
  free(builder);
}

AnvilTSProjectBuilder *anvil_ts_project_builder_create(uint32_t usage_cap) {
  SDL_Mutex *registry = project_registry_mutex();
  if (!registry) return NULL;
  AnvilTSProjectBuilder *builder = (AnvilTSProjectBuilder *)calloc(1, sizeof(*builder));
  if (!builder) return NULL;
  SDL_SetAtomicInt(&builder->refcount, 2); /* Lua owner plus registry ownership. */
  builder->mutex = SDL_CreateMutex();
  builder->usage_cap = usage_cap;
  builder->id = (uint64_t)(uint32_t)(SDL_AddAtomicInt(&registry_sequence, 1) + 1);
  if (!builder->mutex || !builder->id) {
    if (builder->mutex) SDL_DestroyMutex(builder->mutex);
    free(builder);
    return NULL;
  }
  SDL_LockMutex(registry);
  builder->registry_next = registry_builders;
  builder->registered = true;
  registry_builders = builder;
  SDL_UnlockMutex(registry);
  return builder;
}

void anvil_ts_project_builder_close(AnvilTSProjectBuilder *builder) {
  if (!builder) return;
  SDL_LockMutex(builder->mutex);
  builder->closed = true;
  SDL_UnlockMutex(builder->mutex);
  SDL_Mutex *mutex = project_registry_mutex();
  bool removed = false;
  if (mutex) {
    SDL_LockMutex(mutex);
    if (builder->registered) {
      AnvilTSProjectBuilder **cursor = &registry_builders;
      while (*cursor) {
        if (*cursor == builder) { *cursor = builder->registry_next; removed = true; break; }
        cursor = &(*cursor)->registry_next;
      }
      builder->registered = false;
    }
    SDL_UnlockMutex(mutex);
  }
  if (removed) anvil_ts_project_builder_release(builder); /* registry */
  anvil_ts_project_builder_release(builder); /* Lua owner */
}

AnvilTSProjectBuilder *anvil_ts_project_builder_create_from_snapshot(const AnvilTSProjectSnapshot *snapshot, uint32_t usage_cap) {
  AnvilTSProjectBuilder *builder = anvil_ts_project_builder_create(usage_cap);
  if (!builder || !snapshot) return builder;
  if (!grow_array((void **)&builder->files, &builder->file_capacity, snapshot->file_count, sizeof(*builder->files)) ||
      !rebuild_path_slots(builder, snapshot->file_count)) {
    anvil_ts_project_builder_close(builder);
    return NULL;
  }
  for (uint32_t i = 0; i < snapshot->file_count; i++) {
    ProjectFileEntry *target = &builder->files[builder->file_count];
    const ProjectFileEntry *source = &snapshot->files[i];
    target->fingerprint = project_strdup(source->fingerprint);
    if (!target->fingerprint) {
      anvil_ts_project_builder_close(builder);
      return NULL;
    }
    anvil_ts_project_file_retain(source->file);
    target->file = source->file;
    target->usage_complete = source->usage_complete;
    insert_path_slot(builder, builder->file_count);
    builder->file_count++;
  }
  builder->version++;
  return builder;
}

uint64_t anvil_ts_project_builder_id(const AnvilTSProjectBuilder *builder) {
  return builder ? builder->id : 0;
}

AnvilTSProjectBuilder *anvil_ts_project_builder_open(uint64_t id) {
  SDL_Mutex *mutex = project_registry_mutex();
  if (!mutex || !id) return NULL;
  SDL_LockMutex(mutex);
  AnvilTSProjectBuilder *found = registry_builders;
  while (found && found->id != id) found = found->registry_next;
  if (found) anvil_ts_project_builder_retain(found);
  SDL_UnlockMutex(mutex);
  return found;
}

bool anvil_ts_project_builder_adopt_batch(
  AnvilTSProjectBuilder *builder,
  AnvilTSProjectFileResult **files,
  const char *const *fingerprints,
  const bool *usage_complete,
  uint32_t count,
  char **error
) {
  if (error) *error = NULL;
  if (!builder || (count && !files)) { set_error(error, "invalid native Project builder batch adoption"); return false; }
  char **fingerprint_copies = count ? (char **)calloc(count, sizeof(*fingerprint_copies)) : NULL;
  ProjectFileEntry *replaced = count ? (ProjectFileEntry *)calloc(count, sizeof(*replaced)) : NULL;
  if (count && (!fingerprint_copies || !replaced)) goto oom;
  for (uint32_t i = 0; i < count; i++) {
    if (!files[i]) { set_error(error, "native Project builder batch contains an empty file"); goto fail; }
    fingerprint_copies[i] = project_strdup(fingerprints ? fingerprints[i] : "");
    if (!fingerprint_copies[i]) goto oom;
  }

  SDL_LockMutex(builder->mutex);
  if (builder->frozen || builder->closed) {
    bool closed = builder->closed;
    SDL_UnlockMutex(builder->mutex);
    set_error(error, closed ? "native Project builder is closed" : "native Project builder is frozen");
    goto fail;
  }
  if (count > UINT32_MAX - builder->file_count ||
      !grow_array((void **)&builder->files, &builder->file_capacity, builder->file_count + count, sizeof(*builder->files)) ||
      !rebuild_path_slots(builder, builder->file_count + count)) {
    SDL_UnlockMutex(builder->mutex);
    goto oom;
  }
  uint32_t replaced_count = 0;
  for (uint32_t i = 0; i < count; i++) {
    const char *path = anvil_ts_project_file_path(files[i]);
    uint32_t existing_index = builder_file_index(builder, path);
    ProjectFileEntry entry = { files[i], fingerprint_copies[i], usage_complete ? usage_complete[i] : true };
    fingerprint_copies[i] = NULL;
    if (existing_index != UINT32_MAX) {
      replaced[replaced_count++] = builder->files[existing_index];
      builder->files[existing_index] = entry;
    } else {
      uint32_t added_index = builder->file_count++;
      builder->files[added_index] = entry;
      insert_path_slot(builder, added_index);
    }
  }
  builder->version++;
  SDL_UnlockMutex(builder->mutex);
  for (uint32_t i = 0; i < replaced_count; i++) release_file_entry(&replaced[i]);
  free(replaced);
  free(fingerprint_copies);
  return true;

oom:
  set_error(error, "out of memory adopting native Project batch");
fail:
  if (fingerprint_copies) {
    for (uint32_t i = 0; i < count; i++) free(fingerprint_copies[i]);
  }
  free(replaced);
  free(fingerprint_copies);
  return false;
}

bool anvil_ts_project_builder_adopt(
  AnvilTSProjectBuilder *builder,
  AnvilTSProjectFileResult *file,
  const char *fingerprint,
  bool usage_complete,
  char **error
) {
  AnvilTSProjectFileResult *files[] = { file };
  const char *fingerprints[] = { fingerprint };
  bool completeness[] = { usage_complete };
  return anvil_ts_project_builder_adopt_batch(builder, files, fingerprints, completeness, 1, error);
}

static int project_path_compare(const char *left, const char *right) {
#ifdef _WIN32
  return SDL_strcasecmp(left ? left : "", right ? right : "");
#else
  return strcmp(left ? left : "", right ? right : "");
#endif
}

static bool project_path_in_scope(const char *path, const char *scope) {
  if (!path || !scope) return false;
  size_t scope_len = strlen(scope);
  while (scope_len > 1 && (scope[scope_len - 1] == '/' || scope[scope_len - 1] == '\\') &&
      !(scope_len == 3 && scope[1] == ':')) scope_len--;
  if (!scope_len) return false;
#ifdef _WIN32
  if (SDL_strncasecmp(path, scope, scope_len) != 0) return false;
#else
  if (strncmp(path, scope, scope_len) != 0) return false;
#endif
  if (scope[scope_len - 1] == '/' || scope[scope_len - 1] == '\\') return true;
  return path[scope_len] == '\0' || path[scope_len] == '/' || path[scope_len] == '\\';
}

bool anvil_ts_project_builder_remove(AnvilTSProjectBuilder *builder, const char *path) {
  if (!builder || !path) return false;
  SDL_LockMutex(builder->mutex);
  if (builder->frozen || builder->closed) { SDL_UnlockMutex(builder->mutex); return false; }
  uint32_t index = builder_file_index(builder, path);
  if (index == UINT32_MAX) { SDL_UnlockMutex(builder->mutex); return false; }
  uint32_t slot = (uint32_t)path_hash(path) & (builder->path_slot_count - 1);
  while (builder->path_slots[slot] != index + 1) slot = (slot + 1) & (builder->path_slot_count - 1);
  builder->path_slots[slot] = 0;
  uint32_t cursor = (slot + 1) & (builder->path_slot_count - 1);
  while (builder->path_slots[cursor]) {
    uint32_t moved = builder->path_slots[cursor] - 1;
    builder->path_slots[cursor] = 0;
    insert_path_slot(builder, moved);
    cursor = (cursor + 1) & (builder->path_slot_count - 1);
  }
  ProjectFileEntry removed = builder->files[index];
  uint32_t last = --builder->file_count;
  if (index != last) {
    builder->files[index] = builder->files[last];
    const char *moved_path = anvil_ts_project_file_path(builder->files[index].file);
    uint32_t moved_slot = (uint32_t)path_hash(moved_path) & (builder->path_slot_count - 1);
    while (builder->path_slots[moved_slot] != last + 1) moved_slot = (moved_slot + 1) & (builder->path_slot_count - 1);
    builder->path_slots[moved_slot] = index + 1;
  }
  memset(&builder->files[last], 0, sizeof(builder->files[last]));
  builder->version++;
  SDL_UnlockMutex(builder->mutex);
  release_file_entry(&removed);
  return true;
}

bool anvil_ts_project_builder_fingerprint_matches(AnvilTSProjectBuilder *builder, const char *path, const char *fingerprint) {
  if (!builder || !path || !fingerprint) return false;
  SDL_LockMutex(builder->mutex);
  uint32_t index = builder_file_index(builder, path);
  bool matches = index != UINT32_MAX && builder->files[index].fingerprint &&
    strcmp(builder->files[index].fingerprint, fingerprint) == 0;
  SDL_UnlockMutex(builder->mutex);
  return matches;
}

static bool sorted_paths_contains(const char *const *paths, uint32_t count, const char *path) {
  uint32_t low = 0, high = count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    int order = project_path_compare(paths[middle], path);
    if (order < 0) low = middle + 1; else high = middle;
  }
  return low < count && project_path_compare(paths[low], path) == 0;
}

bool anvil_ts_project_builder_remove_scope_missing(
  AnvilTSProjectBuilder *builder,
  const char *const *scope_paths,
  uint32_t scope_count,
  const char *const *seen_paths,
  uint32_t seen_count,
  char **error
) {
  if (error) *error = NULL;
  if (!builder || (scope_count && !scope_paths) || (seen_count && !seen_paths)) {
    set_error(error, "invalid native Project scoped removal");
    return false;
  }
  SDL_LockMutex(builder->mutex);
  uint32_t remove_count = 0;
  for (uint32_t i = 0; i < builder->file_count; i++) {
    const char *path = anvil_ts_project_file_path(builder->files[i].file);
    bool scoped = false;
    for (uint32_t s = 0; s < scope_count && !scoped; s++) scoped = project_path_in_scope(path, scope_paths[s]);
    if (scoped && !sorted_paths_contains(seen_paths, seen_count, path)) remove_count++;
  }
  char **remove_paths = remove_count ? (char **)calloc(remove_count, sizeof(*remove_paths)) : NULL;
  if (remove_count && !remove_paths) {
    SDL_UnlockMutex(builder->mutex);
    set_error(error, "out of memory preparing native Project scoped removal");
    return false;
  }
  uint32_t remove_index = 0;
  for (uint32_t i = 0; i < builder->file_count; i++) {
    const char *path = anvil_ts_project_file_path(builder->files[i].file);
    bool scoped = false;
    for (uint32_t s = 0; s < scope_count && !scoped; s++) scoped = project_path_in_scope(path, scope_paths[s]);
    if (scoped && !sorted_paths_contains(seen_paths, seen_count, path)) {
      remove_paths[remove_index] = project_strdup(path);
      if (!remove_paths[remove_index]) {
        for (uint32_t r = 0; r < remove_index; r++) free(remove_paths[r]);
        free(remove_paths);
        SDL_UnlockMutex(builder->mutex);
        set_error(error, "out of memory copying native Project scoped removal path");
        return false;
      }
      remove_index++;
    }
  }
  SDL_UnlockMutex(builder->mutex);
  for (uint32_t i = 0; i < remove_count; i++) {
    (void)anvil_ts_project_builder_remove(builder, remove_paths[i]);
    free(remove_paths[i]);
  }
  free(remove_paths);
  return true;
}

static int file_compare(const void *left, const void *right) {
  const ProjectFileEntry *a = (const ProjectFileEntry *)left;
  const ProjectFileEntry *b = (const ProjectFileEntry *)right;
  const char *ap = anvil_ts_project_file_relpath(a->file);
  const char *bp = anvil_ts_project_file_relpath(b->file);
  int compared = strcmp(ap ? ap : "", bp ? bp : "");
  if (compared) return compared;
  const char *af = anvil_ts_project_file_path(a->file);
  const char *bf = anvil_ts_project_file_path(b->file);
  return strcmp(af ? af : "", bf ? bf : "");
}

static int bytes_compare(const char *a, uint32_t a_len, const char *b, uint32_t b_len) {
  uint32_t common = a_len < b_len ? a_len : b_len;
  int compared = common ? memcmp(a, b, common) : 0;
  if (compared) return compared;
  return a_len < b_len ? -1 : a_len > b_len;
}

static int symbol_ref_compare(const void *left, const void *right) {
  const ProjectRecordRef *a = (const ProjectRecordRef *)left;
  const ProjectRecordRef *b = (const ProjectRecordRef *)right;
  int compared = strcmp(anvil_ts_project_file_relpath(a->file), anvil_ts_project_file_relpath(b->file));
  if (compared) return compared;
  compared = strcmp(anvil_ts_project_file_path(a->file), anvil_ts_project_file_path(b->file));
  if (compared) return compared;
  AnvilTSProjectSymbolView av, bv;
  anvil_ts_project_file_symbol_at(a->file, a->index, &av);
  anvil_ts_project_file_symbol_at(b->file, b->index, &bv);
  if (av.range.start_point.row != bv.range.start_point.row) return av.range.start_point.row < bv.range.start_point.row ? -1 : 1;
  if (av.range.start_point.column != bv.range.start_point.column) return av.range.start_point.column < bv.range.start_point.column ? -1 : 1;
  if (av.range.end_point.row != bv.range.end_point.row) return av.range.end_point.row < bv.range.end_point.row ? -1 : 1;
  if (av.range.end_point.column != bv.range.end_point.column) return av.range.end_point.column < bv.range.end_point.column ? -1 : 1;
  compared = bytes_compare(av.name, av.name_len, bv.name, bv.name_len);
  if (compared) return compared;
  compared = bytes_compare(av.kind, av.kind_len, bv.kind, bv.kind_len);
  if (compared) return compared;
  return a->index < b->index ? -1 : a->index > b->index;
}

static int usage_ref_compare(const void *left, const void *right) {
  const ProjectRecordRef *a = (const ProjectRecordRef *)left;
  const ProjectRecordRef *b = (const ProjectRecordRef *)right;
  int compared = strcmp(anvil_ts_project_file_relpath(a->file), anvil_ts_project_file_relpath(b->file));
  if (compared) return compared;
  compared = strcmp(anvil_ts_project_file_path(a->file), anvil_ts_project_file_path(b->file));
  if (compared) return compared;
  AnvilTSProjectUsageView av, bv;
  anvil_ts_project_file_usage_at(a->file, a->index, &av);
  anvil_ts_project_file_usage_at(b->file, b->index, &bv);
  if (av.range.start_point.row != bv.range.start_point.row) return av.range.start_point.row < bv.range.start_point.row ? -1 : 1;
  if (av.range.start_point.column != bv.range.start_point.column) return av.range.start_point.column < bv.range.start_point.column ? -1 : 1;
  if (av.range.end_point.row != bv.range.end_point.row) return av.range.end_point.row < bv.range.end_point.row ? -1 : 1;
  if (av.range.end_point.column != bv.range.end_point.column) return av.range.end_point.column < bv.range.end_point.column ? -1 : 1;
  compared = bytes_compare(av.capture, av.capture_len, bv.capture, bv.capture_len);
  if (compared) return compared;
  compared = bytes_compare(av.name, av.name_len, bv.name, bv.name_len);
  if (compared) return compared;
  if (av.is_declaration != bv.is_declaration) return av.is_declaration ? -1 : 1;
  compared = bytes_compare(av.kind, av.kind_len, bv.kind, bv.kind_len);
  if (compared) return compared;
  return a->index < b->index ? -1 : a->index > b->index;
}

static void snapshot_destroy(AnvilTSProjectSnapshot *snapshot) {
  if (!snapshot) return;
  for (uint32_t i = 0; i < snapshot->file_count; i++) release_file_entry(&snapshot->files[i]);
  for (uint32_t i = 0; i < snapshot->usage_name_count; i++) free(snapshot->usage_names[i].usage_indices);
  free(snapshot->usage_names);
  free(snapshot->usage_name_slots);
  free(snapshot->files);
  fuzzy_index_free(&snapshot->symbol_fuzzy);
  free(snapshot->symbols);
  free(snapshot->usages);
  free(snapshot);
}

static bool build_usage_name_lookup(AnvilTSProjectSnapshot *snapshot) {
  if (!snapshot->usage_count) return true;
  if (snapshot->usage_count > UINT32_MAX / 4) return false;
  uint32_t slot_count = 16;
  while (slot_count / 2 < snapshot->usage_count) slot_count *= 2;
  snapshot->usage_name_slots = (uint32_t *)calloc(slot_count, sizeof(*snapshot->usage_name_slots));
  snapshot->usage_names = (ProjectUsageNameEntry *)calloc(snapshot->usage_count, sizeof(*snapshot->usage_names));
  if (!snapshot->usage_name_slots || !snapshot->usage_names) return false;
  snapshot->usage_name_slot_count = slot_count;
  snapshot->usage_name_capacity = snapshot->usage_count;
  for (uint32_t usage_index = 0; usage_index < snapshot->usage_count; usage_index++) {
    ProjectRecordRef ref = snapshot->usages[usage_index];
    AnvilTSProjectUsageView usage;
    if (!anvil_ts_project_file_usage_at(ref.file, ref.index, &usage)) return false;
    uint32_t slot = (uint32_t)bytes_hash(usage.name, usage.name_len) & (slot_count - 1);
    ProjectUsageNameEntry *entry = NULL;
    while (snapshot->usage_name_slots[slot]) {
      ProjectUsageNameEntry *candidate = &snapshot->usage_names[snapshot->usage_name_slots[slot] - 1];
      if (candidate->name_len == usage.name_len && (!usage.name_len || memcmp(candidate->name, usage.name, usage.name_len) == 0)) {
        entry = candidate;
        break;
      }
      slot = (slot + 1) & (slot_count - 1);
    }
    if (!entry) {
      uint32_t entry_index = snapshot->usage_name_count++;
      entry = &snapshot->usage_names[entry_index];
      entry->name = usage.name;
      entry->name_len = usage.name_len;
      snapshot->usage_name_slots[slot] = entry_index + 1;
    }
    if (!grow_array((void **)&entry->usage_indices, &entry->usage_capacity, entry->usage_count + 1, sizeof(*entry->usage_indices))) return false;
    entry->usage_indices[entry->usage_count++] = usage_index;
  }
  return true;
}

AnvilTSProjectSnapshot *anvil_ts_project_builder_snapshot(
  AnvilTSProjectBuilder *builder,
  const char *status,
  bool freeze,
  char **error
) {
  if (error) *error = NULL;
  if (!builder) { set_error(error, "invalid native Project builder snapshot request"); return NULL; }
  AnvilTSProjectSnapshot *snapshot = (AnvilTSProjectSnapshot *)calloc(1, sizeof(*snapshot));
  if (!snapshot) { set_error(error, "out of memory allocating native Project snapshot"); return NULL; }
  SDL_SetAtomicInt(&snapshot->refcount, 1);
  SDL_strlcpy(snapshot->status, status && *status ? status : (freeze ? "ready" : "partial"), sizeof(snapshot->status));
  snapshot->usage_complete = true;

  SDL_LockMutex(builder->mutex);
  if (builder->closed || (freeze && builder->frozen)) {
    bool closed = builder->closed;
    SDL_UnlockMutex(builder->mutex);
    snapshot_destroy(snapshot);
    set_error(error, closed ? "native Project builder is closed" : "native Project builder is already frozen");
    return NULL;
  }
  uint64_t builder_version = builder->version;
  snapshot->file_count = builder->file_count;
  if (snapshot->file_count) snapshot->files = (ProjectFileEntry *)calloc(snapshot->file_count, sizeof(*snapshot->files));
  if (snapshot->file_count && !snapshot->files) {
    SDL_UnlockMutex(builder->mutex);
    snapshot_destroy(snapshot);
    set_error(error, "out of memory copying native Project snapshot files");
    return NULL;
  }
  uint64_t symbol_total = 0, usage_total = 0;
  for (uint32_t i = 0; i < snapshot->file_count; i++) {
    ProjectFileEntry *source = &builder->files[i];
    anvil_ts_project_file_retain(source->file);
    snapshot->files[i].file = source->file;
    snapshot->files[i].fingerprint = project_strdup(source->fingerprint);
    snapshot->files[i].usage_complete = source->usage_complete;
    if (!snapshot->files[i].fingerprint) {
      SDL_UnlockMutex(builder->mutex);
      snapshot_destroy(snapshot);
      set_error(error, "out of memory copying native Project snapshot metadata");
      return NULL;
    }
    symbol_total += anvil_ts_project_file_symbol_count(source->file);
    usage_total += anvil_ts_project_file_usage_count(source->file);
    snapshot->usage_complete = snapshot->usage_complete && source->usage_complete;
  }
  uint32_t usage_cap = builder->usage_cap;
  SDL_UnlockMutex(builder->mutex);

  if (symbol_total > UINT32_MAX || usage_total > UINT32_MAX) {
    snapshot_destroy(snapshot);
    set_error(error, "native Project snapshot record count exceeds uint32 range");
    return NULL;
  }
  qsort(snapshot->files, snapshot->file_count, sizeof(*snapshot->files), file_compare);
  snapshot->symbol_count = (uint32_t)symbol_total;
  uint32_t raw_usage_count = (uint32_t)usage_total;
  snapshot->usage_count = raw_usage_count < usage_cap ? raw_usage_count : usage_cap;
  snapshot->usage_truncated = raw_usage_count > snapshot->usage_count || !snapshot->usage_complete;
  if (snapshot->symbol_count) snapshot->symbols = (ProjectRecordRef *)malloc((size_t)snapshot->symbol_count * sizeof(*snapshot->symbols));
  if (snapshot->usage_count) snapshot->usages = (ProjectRecordRef *)malloc((size_t)snapshot->usage_count * sizeof(*snapshot->usages));
  if ((snapshot->symbol_count && !snapshot->symbols) || (snapshot->usage_count && !snapshot->usages)) {
    snapshot_destroy(snapshot);
    set_error(error, "out of memory allocating native Project snapshot records");
    return NULL;
  }
  uint32_t symbol_index = 0, usage_index = 0;
  for (uint32_t file_index = 0; file_index < snapshot->file_count; file_index++) {
    AnvilTSProjectFileResult *file = snapshot->files[file_index].file;
    uint32_t count = anvil_ts_project_file_symbol_count(file);
    for (uint32_t i = 0; i < count; i++) snapshot->symbols[symbol_index++] = (ProjectRecordRef) { file, i };
    count = anvil_ts_project_file_usage_count(file);
    for (uint32_t i = 0; i < count && usage_index < snapshot->usage_count; i++) {
      snapshot->usages[usage_index++] = (ProjectRecordRef) { file, i };
    }
  }
  qsort(snapshot->symbols, snapshot->symbol_count, sizeof(*snapshot->symbols), symbol_ref_compare);
  qsort(snapshot->usages, snapshot->usage_count, sizeof(*snapshot->usages), usage_ref_compare);
  const char **fuzzy_items = snapshot->symbol_count
    ? (const char **)malloc((size_t)snapshot->symbol_count * sizeof(*fuzzy_items)) : NULL;
  if (snapshot->symbol_count && !fuzzy_items) {
    snapshot_destroy(snapshot);
    set_error(error, "out of memory preparing native Project symbol fuzzy index");
    return NULL;
  }
  for (uint32_t i = 0; i < snapshot->symbol_count; i++) {
    AnvilTSProjectSymbolView symbol;
    anvil_ts_project_file_symbol_at(snapshot->symbols[i].file, snapshot->symbols[i].index, &symbol);
    fuzzy_items[i] = symbol.name;
  }
  bool fuzzy_ok = fuzzy_index_build(&snapshot->symbol_fuzzy, fuzzy_items, snapshot->symbol_count, FUZZY_MODE_GENERIC);
  free(fuzzy_items);
  if (!fuzzy_ok) {
    snapshot_destroy(snapshot);
    set_error(error, "out of memory building native Project symbol fuzzy index");
    return NULL;
  }
  if (!build_usage_name_lookup(snapshot)) {
    snapshot_destroy(snapshot);
    set_error(error, "out of memory building native Project usage-name lookup");
    return NULL;
  }
  if (freeze) {
    SDL_LockMutex(builder->mutex);
    bool unchanged = !builder->closed && !builder->frozen && builder->version == builder_version;
    if (unchanged) builder->frozen = true;
    SDL_UnlockMutex(builder->mutex);
    if (!unchanged) {
      snapshot_destroy(snapshot);
      set_error(error, "native Project builder changed while freezing");
      return NULL;
    }
  }
  return snapshot;
}

void anvil_ts_project_snapshot_retain(AnvilTSProjectSnapshot *snapshot) {
  if (snapshot) SDL_AtomicIncRef(&snapshot->refcount);
}

void anvil_ts_project_snapshot_release(AnvilTSProjectSnapshot *snapshot) {
  if (snapshot && SDL_AtomicDecRef(&snapshot->refcount)) snapshot_destroy(snapshot);
}

void anvil_ts_project_snapshot_summary(const AnvilTSProjectSnapshot *snapshot, AnvilTSProjectSnapshotSummary *summary) {
  if (!summary) return;
  memset(summary, 0, sizeof(*summary));
  if (!snapshot) return;
  summary->status = snapshot->status;
  summary->files = snapshot->file_count;
  summary->symbols = snapshot->symbol_count;
  summary->usages = snapshot->usage_count;
  summary->usage_names = snapshot->usage_name_count;
  summary->usage_truncated = snapshot->usage_truncated;
  summary->usage_complete = snapshot->usage_complete && !snapshot->usage_truncated;
}

bool anvil_ts_project_snapshot_file_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectSnapshotFileView *view) {
  if (!snapshot || !view || index >= snapshot->file_count) return false;
  view->file = snapshot->files[index].file;
  view->fingerprint = snapshot->files[index].fingerprint;
  view->usage_complete = snapshot->files[index].usage_complete;
  return true;
}

bool anvil_ts_project_snapshot_symbol_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectFileResult **file, uint32_t *file_symbol_index) {
  if (!snapshot || index >= snapshot->symbol_count) return false;
  if (file) *file = snapshot->symbols[index].file;
  if (file_symbol_index) *file_symbol_index = snapshot->symbols[index].index;
  return true;
}

bool anvil_ts_project_snapshot_usage_at(const AnvilTSProjectSnapshot *snapshot, uint32_t index, AnvilTSProjectFileResult **file, uint32_t *file_usage_index) {
  if (!snapshot || index >= snapshot->usage_count) return false;
  if (file) *file = snapshot->usages[index].file;
  if (file_usage_index) *file_usage_index = snapshot->usages[index].index;
  return true;
}

typedef struct ProjectPathRuleSlot {
  const char *path;
  uint64_t hash;
  uint32_t length;
  bool excluded;
} ProjectPathRuleSlot;

typedef struct ProjectPathRuleSet {
  ProjectPathRuleSlot *slots;
  uint32_t slot_count;
} ProjectPathRuleSet;

static uint32_t project_rule_length(const char *path) {
  size_t length = strlen(path ? path : "");
  while (length > 1 && (path[length - 1] == '/' || path[length - 1] == '\\') &&
      !(length == 3 && path[1] == ':')) length--;
  return length > UINT32_MAX ? UINT32_MAX : (uint32_t)length;
}

static uint64_t project_rule_hash(const char *path, uint32_t length) {
  uint64_t hash = UINT64_C(1469598103934665603);
  for (uint32_t i = 0; i < length; i++) {
    unsigned char byte = (unsigned char)path[i];
#ifdef _WIN32
    byte = (unsigned char)SDL_tolower(byte);
#endif
    hash ^= byte;
    hash *= UINT64_C(1099511628211);
  }
  return hash ? hash : 1;
}

static bool project_rule_prefix_equal(const char *rule, const char *path, uint32_t length) {
#ifdef _WIN32
  return SDL_strncasecmp(rule, path, length) == 0;
#else
  return strncmp(rule, path, length) == 0;
#endif
}

static bool project_path_rules_build(
  ProjectPathRuleSet *rules,
  const char *const *excluded_paths,
  uint32_t excluded_count,
  const char *const *included_paths,
  uint32_t included_count
) {
  memset(rules, 0, sizeof(*rules));
  uint64_t count = (uint64_t)excluded_count + included_count;
  if (!count) return true;
  uint32_t slots = 16;
  while ((uint64_t)slots / 2 < count) {
    if (slots > UINT32_MAX / 2) return false;
    slots *= 2;
  }
  rules->slots = (ProjectPathRuleSlot *)calloc(slots, sizeof(*rules->slots));
  if (!rules->slots) return false;
  rules->slot_count = slots;
  for (uint32_t pass = 0; pass < 2; pass++) {
    const char *const *paths = pass == 0 ? included_paths : excluded_paths;
    uint32_t path_count = pass == 0 ? included_count : excluded_count;
    for (uint32_t i = 0; i < path_count; i++) {
      const char *path = paths[i];
      uint32_t length = project_rule_length(path);
      if (!path || !length) continue;
      uint64_t hash = project_rule_hash(path, length);
      uint32_t slot = (uint32_t)hash & (slots - 1);
      while (rules->slots[slot].path) {
        ProjectPathRuleSlot *existing = &rules->slots[slot];
        if (existing->hash == hash && existing->length == length &&
            project_rule_prefix_equal(existing->path, path, length)) {
          if (pass == 1) existing->excluded = true;
          goto inserted;
        }
        slot = (slot + 1) & (slots - 1);
      }
      rules->slots[slot] = (ProjectPathRuleSlot) { path, hash, length, pass == 1 };
inserted:;
    }
  }
  return true;
}

static void project_path_rules_free(ProjectPathRuleSet *rules) {
  free(rules->slots);
  memset(rules, 0, sizeof(*rules));
}

static const ProjectPathRuleSlot *project_path_rule_lookup(
  const ProjectPathRuleSet *rules,
  const char *path,
  uint32_t length,
  uint64_t hash
) {
  if (!rules->slot_count || !length) return NULL;
  uint32_t slot = (uint32_t)hash & (rules->slot_count - 1);
  while (rules->slots[slot].path) {
    const ProjectPathRuleSlot *candidate = &rules->slots[slot];
    if (candidate->hash == hash && candidate->length == length &&
        project_rule_prefix_equal(candidate->path, path, length)) return candidate;
    slot = (slot + 1) & (rules->slot_count - 1);
  }
  return NULL;
}

static bool query_path_excluded(const char *path, const ProjectPathRuleSet *rules) {
  path = path ? path : "";
  uint64_t hash = UINT64_C(1469598103934665603);
  const ProjectPathRuleSlot *matched = NULL;
  for (uint32_t i = 0; path[i]; i++) {
    if ((path[i] == '/' || path[i] == '\\') && i > 0) {
      const ProjectPathRuleSlot *candidate = project_path_rule_lookup(rules, path, i, hash ? hash : 1);
      if (candidate) matched = candidate;
    }
    unsigned char byte = (unsigned char)path[i];
#ifdef _WIN32
    byte = (unsigned char)SDL_tolower(byte);
#endif
    hash ^= byte;
    hash *= UINT64_C(1099511628211);
    if ((i == 0 && (path[i] == '/' || path[i] == '\\')) ||
        (i == 2 && path[1] == ':' && (path[i] == '/' || path[i] == '\\'))) {
      const ProjectPathRuleSlot *candidate = project_path_rule_lookup(rules, path, i + 1, hash ? hash : 1);
      if (candidate) matched = candidate;
    }
  }
  uint32_t length = (uint32_t)strlen(path);
  const ProjectPathRuleSlot *exact = project_path_rule_lookup(rules, path, length, hash ? hash : 1);
  if (exact) matched = exact;
  return matched && matched->excluded;
}

static bool query_symbol_kind_allowed(
  const AnvilTSProjectSymbolView *symbol,
  const char *const *kinds,
  uint32_t kind_count
) {
  if (!kind_count) return true;
  for (uint32_t i = 0; i < kind_count; i++) {
    const char *kind = kinds[i] ? kinds[i] : "";
    size_t length = strlen(kind);
    if (length == symbol->kind_len && (!length || memcmp(symbol->kind, kind, length) == 0)) return true;
  }
  return false;
}

static bool query_symbol_language_allowed(
  const AnvilTSProjectFileResult *file,
  const char *const *languages,
  uint32_t language_count
) {
  if (!language_count) return true;
  const char *language = anvil_ts_project_file_language(file);
  language = language ? language : "";
  for (uint32_t i = 0; i < language_count; i++) {
    if (strcmp(language, languages[i] ? languages[i] : "") == 0) return true;
  }
  return false;
}

static bool query_symbol_parent_allowed(
  const AnvilTSProjectFileResult *file,
  const AnvilTSProjectSymbolView *symbol,
  const char *const *parent_names,
  uint32_t parent_name_count
) {
  if (!parent_name_count) return true;
  if (symbol->parent == UINT32_MAX || symbol->parent == 0) return false;
  AnvilTSProjectSymbolView parent;
  if (!anvil_ts_project_file_symbol_at(file, symbol->parent - 1, &parent)) return false;
  for (uint32_t i = 0; i < parent_name_count; i++) {
    const char *name = parent_names[i] ? parent_names[i] : "";
    size_t length = strlen(name);
    if (length == parent.name_len && (!length || memcmp(parent.name, name, length) == 0)) return true;
  }
  return false;
}

static bool query_symbol_allowed(
  const AnvilTSProjectSnapshot *snapshot,
  uint32_t symbol_index,
  const char *const *kinds,
  uint32_t kind_count,
  const char *const *parent_names,
  uint32_t parent_name_count,
  const char *const *languages,
  uint32_t language_count,
  const ProjectPathRuleSet *path_rules
) {
  ProjectRecordRef ref = snapshot->symbols[symbol_index];
  if (query_path_excluded(anvil_ts_project_file_path(ref.file), path_rules)) return false;
  if (!query_symbol_language_allowed(ref.file, languages, language_count)) return false;
  AnvilTSProjectSymbolView symbol;
  return anvil_ts_project_file_symbol_at(ref.file, ref.index, &symbol) &&
    query_symbol_kind_allowed(&symbol, kinds, kind_count) &&
    query_symbol_parent_allowed(ref.file, &symbol, parent_names, parent_name_count);
}

static bool query_fuzzy_better(const FuzzyIndex *index, const FuzzySearchResult *a, const FuzzySearchResult *b) {
  if (a->score != b->score) return a->score > b->score;
  int compared = strcmp(fuzzy_index_text(index, a->entry_index), fuzzy_index_text(index, b->entry_index));
  if (compared) return compared < 0;
  return a->source_index < b->source_index;
}

static void query_insert_fuzzy(
  const FuzzyIndex *index,
  FuzzySearchResult *top,
  uint32_t *top_count,
  uint32_t capacity,
  FuzzySearchResult candidate
) {
  if (!capacity) return;
  if (*top_count >= capacity && !query_fuzzy_better(index, &candidate, &top[*top_count - 1])) return;
  uint32_t position = *top_count;
  if (*top_count < capacity) (*top_count)++;
  else position = capacity - 1;
  while (position > 0 && query_fuzzy_better(index, &candidate, &top[position - 1])) {
    top[position] = top[position - 1];
    position--;
  }
  top[position] = candidate;
}

static uint32_t query_collect_fuzzy_symbols(
  const AnvilTSProjectSnapshot *snapshot,
  const char *query,
  const char *const *kinds,
  uint32_t kind_count,
  const char *const *parent_names,
  uint32_t parent_name_count,
  const char *const *languages,
  uint32_t language_count,
  const ProjectPathRuleSet *path_rules,
  const FuzzySearchResult *after,
  FuzzySearchResult *top,
  uint32_t capacity,
  uint32_t *matched_total
) {
  uint32_t top_count = 0, matched = 0;
  for (uint32_t i = 0; i < snapshot->symbol_count; i++) {
    if (!query_symbol_allowed(snapshot, i, kinds, kind_count, parent_names, parent_name_count,
        languages, language_count, path_rules)) continue;
    const FuzzyEntry *entry = &snapshot->symbol_fuzzy.entries[i];
    const char *text = snapshot->symbol_fuzzy.text_arena + entry->text_offset;
    const char *lower = snapshot->symbol_fuzzy.lower_arena + entry->lower_offset;
    int score = fuzzy_match_score(FUZZY_MODE_GENERIC, text, lower, entry->len, entry->basename_start, query);
    if (score == INT_MIN) continue;
    FuzzySearchResult candidate = { i, i + 1, score };
    matched++;
    if (after && !query_fuzzy_better(&snapshot->symbol_fuzzy, after, &candidate)) continue;
    query_insert_fuzzy(&snapshot->symbol_fuzzy, top, &top_count, capacity, candidate);
  }
  if (matched_total) *matched_total = matched;
  return top_count;
}

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
) {
  if (indices) *indices = NULL;
  if (count) *count = 0;
  if (total) *total = 0;
  if (has_more) *has_more = false;
  if (!snapshot || !indices || (kind_count && !kinds) || (parent_name_count && !parent_names) ||
      (language_count && !languages) ||
      (excluded_path_count && !excluded_paths) ||
      (included_path_count && !included_paths)) return false;
  ProjectPathRuleSet path_rules;
  if (!project_path_rules_build(&path_rules, excluded_paths, excluded_path_count,
      included_paths, included_path_count)) return false;
  if (offset > snapshot->symbol_count) offset = snapshot->symbol_count;
  uint32_t *out = limit ? (uint32_t *)malloc((size_t)limit * sizeof(*out)) : NULL;
  if (limit && !out) { project_path_rules_free(&path_rules); return false; }
  uint32_t matched = 0, out_count = 0;
  query = query ? query : "";
  if (!*query) {
    for (uint32_t i = 0; i < snapshot->symbol_count; i++) {
      if (!query_symbol_allowed(snapshot, i, kinds, kind_count, parent_names, parent_name_count,
          languages, language_count, &path_rules)) continue;
      if (matched >= offset && out_count < limit) out[out_count++] = i;
      matched++;
    }
  } else {
    FuzzySearchResult cursor;
    const FuzzySearchResult *after = NULL;
    uint32_t remaining = offset;
    bool beyond_end = false;
    while (remaining) {
      uint32_t step = remaining < 4096 ? remaining : 4096;
      FuzzySearchResult *scratch = (FuzzySearchResult *)malloc((size_t)step * sizeof(*scratch));
      if (!scratch) { free(out); project_path_rules_free(&path_rules); return false; }
      uint32_t top_count = query_collect_fuzzy_symbols(snapshot, query, kinds, kind_count,
        parent_names, parent_name_count, languages, language_count, &path_rules, after, scratch, step, &matched);
      if (top_count < step) {
        beyond_end = true;
        free(scratch);
        break;
      }
      cursor = scratch[step - 1];
      after = &cursor;
      remaining -= step;
      free(scratch);
    }
    if (!beyond_end) {
      FuzzySearchResult *page = limit ? (FuzzySearchResult *)malloc((size_t)limit * sizeof(*page)) : NULL;
      if (limit && !page) { free(out); project_path_rules_free(&path_rules); return false; }
      uint32_t page_count = query_collect_fuzzy_symbols(snapshot, query, kinds, kind_count,
        parent_names, parent_name_count, languages, language_count, &path_rules, after, page, limit, &matched);
      for (uint32_t i = 0; i < page_count; i++) out[out_count++] = page[i].entry_index;
      free(page);
    }
  }
  *indices = out;
  if (count) *count = out_count;
  if (total) *total = matched;
  if (has_more) *has_more = matched > offset + out_count;
  project_path_rules_free(&path_rules);
  return true;
}

static ProjectUsageNameEntry *snapshot_usage_name(
  const AnvilTSProjectSnapshot *snapshot,
  const char *name,
  uint32_t name_len
) {
  if (!snapshot->usage_name_slot_count) return NULL;
  uint32_t slot = (uint32_t)bytes_hash(name, name_len) & (snapshot->usage_name_slot_count - 1);
  while (snapshot->usage_name_slots[slot]) {
    ProjectUsageNameEntry *entry = &snapshot->usage_names[snapshot->usage_name_slots[slot] - 1];
    if (entry->name_len == name_len && (!name_len || memcmp(entry->name, name, name_len) == 0)) return entry;
    slot = (slot + 1) & (snapshot->usage_name_slot_count - 1);
  }
  return NULL;
}

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
) {
  if (indices) *indices = NULL;
  if (count) *count = 0;
  if (total) *total = 0;
  if (has_more) *has_more = false;
  if (!snapshot || !name || !indices || (excluded_path_count && !excluded_paths) ||
      (included_path_count && !included_paths)) return false;
  ProjectPathRuleSet path_rules;
  if (!project_path_rules_build(&path_rules, excluded_paths, excluded_path_count,
      included_paths, included_path_count)) return false;
  ProjectUsageNameEntry *entry = snapshot_usage_name(snapshot, name, name_len);
  uint32_t available = entry ? entry->usage_count : 0;
  if (offset > available) offset = available;
  uint32_t *out = limit ? (uint32_t *)malloc((size_t)limit * sizeof(*out)) : NULL;
  if (limit && !out) { project_path_rules_free(&path_rules); return false; }
  uint32_t matched = 0, out_count = 0;
  for (uint32_t i = 0; i < available; i++) {
    uint32_t usage_index = entry->usage_indices[i];
    ProjectRecordRef ref = snapshot->usages[usage_index];
    AnvilTSProjectUsageView usage;
    if (!anvil_ts_project_file_usage_at(ref.file, ref.index, &usage)) continue;
    if (!include_declarations && usage.is_declaration) continue;
    if (query_path_excluded(anvil_ts_project_file_path(ref.file), &path_rules)) continue;
    if (matched >= offset && out_count < limit) out[out_count++] = usage_index;
    matched++;
  }
  *indices = out;
  if (count) *count = out_count;
  if (total) *total = matched;
  if (has_more) *has_more = matched > offset + out_count;
  project_path_rules_free(&path_rules);
  return true;
}
