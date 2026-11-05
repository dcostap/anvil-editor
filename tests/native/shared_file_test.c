#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "shared_file.h"

/* Seam: a reader must not report absence during a replacement's missing-name interval. */
typedef struct {
  const wchar_t *path;
  HANDLE started, done;
  DWORD error;
  char text[32];
} Reader;

static DWORD WINAPI read_value(void *data) {
  Reader *reader = data;
  SetEvent(reader->started);
  HANDLE file = anvil_shared_file_open(reader->path, &reader->error);
  if (file != INVALID_HANDLE_VALUE) {
    DWORD count;
    if (!ReadFile(file, reader->text, sizeof(reader->text) - 1, &count, NULL)) reader->error = GetLastError();
    CloseHandle(file);
  }
  SetEvent(reader->done);
  return 0;
}

static bool write_value(const wchar_t *path) {
  HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
    NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD count;
  bool ok = WriteFile(file, "complete value", 14, &count, NULL) && count == 14;
  CloseHandle(file);
  return ok;
}

int main(void) {
  wchar_t temp[MAX_PATH], directory[MAX_PATH], path[MAX_PATH], alias[MAX_PATH];
  DWORD error = 0;
  if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"anv", 0, directory)) return 1;
  DeleteFileW(directory);
  if (!CreateDirectoryW(directory, NULL)) return 1;
  swprintf(path, MAX_PATH, L"%ls\\record-\u00e9", directory);
  swprintf(alias, MAX_PATH, L"%ls\\.\\RECORD-\u00c9", directory);
  HANDLE lock = anvil_file_replace_begin(path, &error);
  if (!lock) { RemoveDirectoryW(directory); return 1; }
  Reader reader = { .path = alias, .started = CreateEventW(NULL, TRUE, FALSE, NULL),
    .done = CreateEventW(NULL, TRUE, FALSE, NULL) };
  HANDLE thread = reader.started && reader.done ? CreateThread(NULL, 0, read_value, &reader, 0, NULL) : NULL;
  bool ok = thread && WaitForSingleObject(reader.started, 5000) == WAIT_OBJECT_0;
  /* Model the interval where a filesystem rename has removed the old name but not published the new one. */
  if (ok && WaitForSingleObject(reader.done, 100) != WAIT_TIMEOUT) {
    fprintf(stderr, "FAIL: a reader reported absence while replacement owned the path (error %lu)\n", reader.error);
    ok = false;
  }
  bool written = write_value(path);
  bool published = anvil_file_replace_end(lock, path, written, &error);
  if (thread) { WaitForSingleObject(thread, 5000); CloseHandle(thread); }
  if (!published || reader.error || strcmp(reader.text, "complete value")) {
    fprintf(stderr, "FAIL: the reader did not receive the published value (error %lu)\n", reader.error);
    ok = false;
  }
  if (reader.started) CloseHandle(reader.started);
  if (reader.done) CloseHandle(reader.done);
  DeleteFileW(path);
  HANDLE absent = anvil_shared_file_open(path, &error);
  if (absent != INVALID_HANDLE_VALUE) { CloseHandle(absent); ok = false; }
  if (error != ERROR_FILE_NOT_FOUND) { fprintf(stderr, "FAIL: a missing key did not report not found\n"); ok = false; }
  RemoveDirectoryW(directory);
  return ok ? 0 : 1;
}
