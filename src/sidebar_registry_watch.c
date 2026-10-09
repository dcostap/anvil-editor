#include "sidebar_registry_watch.h"
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>

struct AnvilSidebarWatch {
  char *path;
  HWND window;
  UINT message;
  HANDLE stop;
  SDL_Thread *thread;
  SDL_AtomicInt done;
};

static bool registry_record(const WCHAR *name, DWORD length) {
  size_t count = length / sizeof(WCHAR);
  return count > 4 &&
         CompareStringOrdinal(name + count - 4, 4, L".lua", 4, TRUE) == CSTR_EQUAL;
}

static int SDLCALL watch_worker(void *data) {
  AnvilSidebarWatch *watch = data;
  wchar_t *path =
      (wchar_t *)SDL_iconv_string("UTF-16LE", "UTF-8", watch->path, strlen(watch->path) + 1);
  if (path && !CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
    SDL_free(path);
    SDL_Log("Sidebar registry directory unavailable; use explicit Refresh");
    SDL_SetAtomicInt(&watch->done, 1);
    return 0;
  }
  HANDLE directory =
      path ? CreateFileW(path, FILE_LIST_DIRECTORY,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL)
           : INVALID_HANDLE_VALUE;
  SDL_free(path);
  OVERLAPPED operation = {0};
  operation.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (directory == INVALID_HANDLE_VALUE || !operation.hEvent)
    goto failed;
  /* DWORD alignment is required by ReadDirectoryChangesW. */
  DWORD buffer[16384];
  HANDLE events[] = {watch->stop, operation.hEvent};
  for (;;) {
    ResetEvent(operation.hEvent);
    if (!ReadDirectoryChangesW(directory, buffer, sizeof(buffer), FALSE,
                               FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE |
                                   FILE_NOTIFY_CHANGE_SIZE,
                               NULL, &operation, NULL))
      goto failed;
    DWORD result = WaitForMultipleObjects(2, events, FALSE, INFINITE);
    if (result != WAIT_OBJECT_0 + 1) {
      CancelIoEx(directory, &operation);
      DWORD ignored;
      GetOverlappedResult(directory, &operation, &ignored, TRUE);
      if (result != WAIT_OBJECT_0)
        goto failed;
      break;
    }
    DWORD bytes;
    if (!GetOverlappedResult(directory, &operation, &bytes, FALSE))
      goto failed;
    bool changed = bytes == 0; /* Notification overflow requires fresh evidence. */
    size_t offset = 0;
    while (offset + sizeof(FILE_NOTIFY_INFORMATION) <= bytes) {
      const FILE_NOTIFY_INFORMATION *item =
          (const FILE_NOTIFY_INFORMATION *)((char *)buffer + offset);
      size_t header = offsetof(FILE_NOTIFY_INFORMATION, FileName);
      if (item->FileNameLength > bytes - offset - header) {
        changed = true;
        break;
      }
      changed |= registry_record(item->FileName, item->FileNameLength);
      if (!item->NextEntryOffset)
        break;
      if (item->NextEntryOffset < header || item->NextEntryOffset > bytes - offset) {
        changed = true;
        break;
      }
      offset += item->NextEntryOffset;
    }
    if (changed && !PostMessageW(watch->window, watch->message, 0, 0))
      goto failed;
  }
  goto finished;
failed:
  SDL_Log("Sidebar registry notifications failed; use explicit Refresh");
finished:
  if (directory != INVALID_HANDLE_VALUE)
    CloseHandle(directory);
  if (operation.hEvent)
    CloseHandle(operation.hEvent);
  SDL_SetAtomicInt(&watch->done, 1);
  return 0;
}

AnvilSidebarWatch *anvil_sidebar_watch_start(const char *userdir, HWND window, UINT message) {
  AnvilSidebarWatch *watch = calloc(1, sizeof(*watch));
  if (!watch)
    return NULL;
  SDL_asprintf(&watch->path, "%s/terminal-sessions", userdir);
  watch->window = window;
  watch->message = message;
  watch->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (watch->path && watch->stop)
    watch->thread = SDL_CreateThread(watch_worker, "sidebar-registry", watch);
  if (!watch->thread) {
    if (watch->stop)
      CloseHandle(watch->stop);
    SDL_free(watch->path);
    free(watch);
    return NULL;
  }
  return watch;
}
bool anvil_sidebar_watch_stop(AnvilSidebarWatch *watch, uint64_t deadline) {
  if (!watch)
    return true;
  SetEvent(watch->stop);
  while (!SDL_GetAtomicInt(&watch->done) && SDL_GetTicks() < deadline)
    SDL_Delay(1);
  if (!SDL_GetAtomicInt(&watch->done))
    return false;
  SDL_WaitThread(watch->thread, NULL);
  CloseHandle(watch->stop);
  SDL_free(watch->path);
  free(watch);
  return true;
}
