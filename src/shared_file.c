#define WIN32_LEAN_AND_MEAN
#include "shared_file.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static bool missing(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

/* Resolve the parent, not the file being replaced. Its identity survives replacement,
   and junctions and different drive-letter casing must reach the same lock. */
static bool mutex_name(const wchar_t *path, wchar_t name[64], DWORD *error) {
  enum { CAPACITY = 32768 };
  wchar_t *full = malloc(2 * CAPACITY * sizeof(*full));
  if (!full) { *error = ERROR_NOT_ENOUGH_MEMORY; return false; }
  wchar_t *parent = full + CAPACITY, *leaf = NULL;
  DWORD length = GetFullPathNameW(path, CAPACITY, full, &leaf);
  if (!length || length >= CAPACITY || !leaf || !*leaf) {
    *error = length >= CAPACITY ? ERROR_FILENAME_EXCED_RANGE : ERROR_INVALID_NAME;
    free(full);
    return false;
  }
  wchar_t *key = full;
  {
    wchar_t first = *leaf;
    *leaf = 0;
    HANDLE directory = CreateFileW(full, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    *leaf = first;
    if (directory != INVALID_HANDLE_VALUE) {
      length = GetFinalPathNameByHandleW(directory, parent, CAPACITY, FILE_NAME_NORMALIZED | VOLUME_NAME_GUID);
      if (!length) length = GetFinalPathNameByHandleW(directory, parent, CAPACITY, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
      CloseHandle(directory);
      if (length && length + wcslen(leaf) + 2 < CAPACITY) {
        if (parent[length - 1] != L'\\') parent[length++] = L'\\';
        wcscpy(parent + length, leaf);
        key = parent;
      }
    }
  }
  /* Filesystems that cannot resolve handle paths still share normalized absolute names. */
  length = (DWORD)wcslen(key);
  CharUpperBuffW(key, length);
  uint64_t hash = UINT64_C(14695981039346656037);
  for (DWORD i = 0; i < length; i++) hash = (hash ^ (uint16_t)key[i]) * UINT64_C(1099511628211);
  swprintf(name, 64, L"Local\\AnvilFileReplace-%016llx", (unsigned long long)hash);
  free(full);
  return true;
}

HANDLE anvil_file_replace_begin(const wchar_t *path, DWORD *error) {
  wchar_t name[64];
  if (!mutex_name(path, name, error)) return NULL;
  HANDLE lock = CreateMutexW(NULL, FALSE, name);
  if (!lock) { *error = GetLastError(); return NULL; }
  DWORD waited = WaitForSingleObject(lock, 2000);
  if (waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED) return lock;
  *error = waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
  CloseHandle(lock);
  return NULL;
}

bool anvil_file_replace_end(HANDLE lock, const wchar_t *path, bool replaced, DWORD *error) {
  if (replaced) {
    *error = ERROR_SUCCESS;
    uint64_t deadline = GetTickCount64() + 50;
    while (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES && missing(GetLastError())) {
      /* The rename already committed. Do not report a failed save after changing the file. */
      if (GetTickCount64() >= deadline) { *error = ERROR_RETRY; break; }
      Sleep(1);
    }
  }
  ReleaseMutex(lock);
  CloseHandle(lock);
  return replaced;
}

HANDLE anvil_shared_file_open(const wchar_t *path, DWORD *error) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  *error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  if (file != INVALID_HANDLE_VALUE || !missing(*error)) return file;
  /* Create the lock even when no writer exists yet. A writer can start between a missing open
     and this retry; opening under the same lock also covers that race. */
  HANDLE lock = anvil_file_replace_begin(path, error);
  if (!lock) return INVALID_HANDLE_VALUE;
  file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  *error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  ReleaseMutex(lock);
  CloseHandle(lock);
  return file;
}
