#define WIN32_LEAN_AND_MEAN
#include "terminal_snapshot.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>

typedef struct {
  char magic[8];
  uint64_t project;
  char id[32];
  uint64_t length;
} DiskHeader;

static uint64_t project_hash(const char *text) {
  uint64_t hash = UINT64_C(14695981039346656037);
  for (; *text; text++) {
    unsigned char ch = *text;
    if (ch == '\\') ch = '/';
    if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
    hash = (hash ^ ch) * UINT64_C(1099511628211);
  }
  return hash;
}

static wchar_t *wide(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  wchar_t *out = count > 0 ? malloc(count * sizeof(wchar_t)) : NULL;
  if (out) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, out, count);
  return out;
}

/* The Project mutex serializes eviction and atomic publication across hosts. */
static bool make_room(const wchar_t *path, uint64_t project) {
  wchar_t directory[32768], pattern[32768];
  if (wcslen(path) >= 32750) return false;
  wcscpy(directory, path);
  wchar_t *slash = wcsrchr(directory, L'\\'), *other = wcsrchr(directory, L'/');
  if (!slash || (other && other > slash)) slash = other;
  if (!slash) return false;
  slash[1] = 0;
  swprintf(pattern, 32768, L"%ls*.snapshot", directory);
  for (;;) {
    WIN32_FIND_DATAW data;
    HANDLE search = FindFirstFileW(pattern, &data);
    if (search == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    size_t count = 0; wchar_t oldest[32768] = {0}; uint64_t oldest_time = UINT64_MAX;
    do {
      if (data.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) continue;
      wchar_t candidate[32768]; swprintf(candidate, 32768, L"%ls%ls", directory, data.cFileName);
      if (!_wcsicmp(path, candidate)) continue;
      FILE *file = _wfopen(candidate, L"rb"); DiskHeader header;
      bool owned = file && fread(&header, sizeof(header), 1, file) == 1 &&
        !memcmp(header.magic, "ANVSNP1", 8) && header.project == project;
      if (file) fclose(file);
      if (!owned) continue;
      count++;
      uint64_t time = ((uint64_t)data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
      if (time < oldest_time) { oldest_time = time; wcscpy(oldest, candidate); }
    } while (FindNextFileW(search, &data));
    DWORD error = GetLastError(); FindClose(search);
    if (error != ERROR_NO_MORE_FILES) return false;
    if (count < ANVIL_TERMINAL_PROJECT_SNAPSHOTS) return true;
    if (!*oldest || !DeleteFileW(oldest)) return false;
  }
}

bool anvil_terminal_snapshot_store(const char *path, const char *project, const char *id,
                                  const uint8_t *bytes, size_t length, DWORD *error) {
  *error = ERROR_INVALID_DATA;
  GhosttyTerminal check = NULL;
  if (strlen(id) != 32 || !length || length > ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT ||
      !anvil_terminal_snapshot_decode(bytes, length, &check)) return false;
  ghostty_terminal_free(check);
  uint64_t owner = project_hash(project);
  wchar_t mutex_name[128];
  swprintf(mutex_name, 128, L"Local\\anvil-snapshot-%016llx", (unsigned long long)owner);
  HANDLE mutex = CreateMutexW(NULL, FALSE, mutex_name);
  DWORD waited = mutex ? WaitForSingleObject(mutex, 5000) : WAIT_FAILED;
  bool locked = waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED;
  wchar_t *dest = wide(path), temporary[32768];
  bool ok = locked && dest && wcslen(dest) < 32730;
  if (ok) {
    wcscpy(temporary, dest);
    wchar_t *slash = wcsrchr(temporary, L'\\'), *other = wcsrchr(temporary, L'/');
    if (!slash || (other && other > slash)) slash = other;
    ok = slash != NULL;
    /* One staging file per Project bounds crash leftovers. The mutex protects it. */
    if (ok) swprintf(slash + 1, 32768 - (slash + 1 - temporary),
      L".anvil-snapshot-%016llx.tmp", (unsigned long long)owner);
  }
  FILE *file = ok ? _wfopen(temporary, L"wb") : NULL;
  DiskHeader header = { .magic = "ANVSNP1", .project = owner, .length = length };
  memcpy(header.id, id, 32);
  ok = file && fwrite(&header, sizeof(header), 1, file) == 1 && fwrite(bytes, 1, length, file) == length;
  if (ok) ok = fflush(file) == 0 && _commit(_fileno(file)) == 0;
  if (file && fclose(file)) ok = false;
  if (ok) ok = make_room(dest, owner) && MoveFileExW(temporary, dest, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  *error = ok ? ERROR_SUCCESS : GetLastError();
  if (!ok && file) DeleteFileW(temporary);
  free(dest);
  if (locked) ReleaseMutex(mutex);
  if (mutex) CloseHandle(mutex);
  return ok;
}

bool anvil_terminal_snapshot_load(const char *path, const char *project, const char *id,
                                 GhosttyTerminal *model, DWORD *error) {
  *model = NULL; *error = ERROR_INVALID_DATA;
  wchar_t *name = wide(path);
  FILE *file = name ? _wfopen(name, L"rb") : NULL;
  free(name);
  if (!file) { *error = ERROR_FILE_NOT_FOUND; return false; }
  DiskHeader header;
  bool ok = strlen(id) == 32 && fread(&header, sizeof(header), 1, file) == 1 &&
    !memcmp(header.magic, "ANVSNP1", 8) && header.project == project_hash(project) &&
    !memcmp(header.id, id, 32) && header.length && header.length <= ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT;
  uint8_t *bytes = ok ? malloc((size_t)header.length) : NULL;
  ok = bytes && fread(bytes, 1, (size_t)header.length, file) == header.length && fgetc(file) == EOF && !ferror(file) &&
    anvil_terminal_snapshot_decode(bytes, (size_t)header.length, model);
  free(bytes); fclose(file);
  if (ok) *error = ERROR_SUCCESS;
  return ok;
}
