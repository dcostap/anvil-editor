#ifdef _WIN32
#include "shell_state.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STATE_HEADER "anvil-shell-windows 1\n"

/* Each Window is one line: `window <x> <y> <w> <h> <maximized> <path bytes> <path>`. */
char *anvil_shell_state_encode(const AnvilShellState *state, size_t *size) {
  if (state->count > ANVIL_SHELL_STATE_MAX_WINDOWS) return NULL;
  size_t capacity = sizeof(STATE_HEADER);
  for (size_t i = 0; i < state->count; i++) {
    size_t length = state->windows[i].path ? strlen(state->windows[i].path) : 0;
    if (length > ANVIL_SHELL_STATE_MAX_PATH) return NULL;
    capacity += length + 96;
  }
  if (capacity > ANVIL_SHELL_STATE_MAX_BYTES) return NULL;
  char *data = malloc(capacity);
  if (!data) return NULL;
  size_t n = (size_t)snprintf(data, capacity, "%s", STATE_HEADER);
  for (size_t i = 0; i < state->count; i++) {
    const AnvilShellWindowState *window = &state->windows[i];
    const char *path = window->path ? window->path : "";
    n += (size_t)snprintf(data + n, capacity - n, "window %ld %ld %ld %ld %d %zu %s\n", (long)window->x,
                          (long)window->y, (long)window->w, (long)window->h, window->maximized ? 1 : 0,
                          strlen(path), path);
  }
  *size = n;
  return data;
}

void anvil_shell_state_free(AnvilShellState *state) {
  for (size_t i = 0; i < state->count; i++) free(state->windows[i].path);
  free(state->windows);
  state->windows = NULL;
  state->count = 0;
}

static bool read_long(const char **cursor, const char *end, long *value) {
  const char *p = *cursor;
  bool negative = p < end && *p == '-';
  if (negative) p++;
  if (p >= end || *p < '0' || *p > '9') return false;
  long long result = 0;
  while (p < end && *p >= '0' && *p <= '9') {
    result = result * 10 + (*p++ - '0');
    if (result > 0x7fffffffLL) return false;
  }
  if (p >= end || *p != ' ') return false;
  *value = (long)(negative ? -result : result);
  *cursor = p + 1;
  return true;
}

bool anvil_shell_state_decode(const char *data, size_t size, AnvilShellState *state) {
  state->windows = NULL;
  state->count = 0;
  size_t header = strlen(STATE_HEADER);
  if (size > ANVIL_SHELL_STATE_MAX_BYTES || size < header || memcmp(data, STATE_HEADER, header)) return false;
  const char *cursor = data + header, *end = data + size;
  state->windows = calloc(ANVIL_SHELL_STATE_MAX_WINDOWS, sizeof(*state->windows));
  if (!state->windows) return false;
  bool complete = true;
  while (cursor < end) {
    long values[6];
    complete = false;
    if (state->count >= ANVIL_SHELL_STATE_MAX_WINDOWS || end - cursor < 7 || memcmp(cursor, "window ", 7)) break;
    cursor += 7;
    bool ok = true;
    for (int i = 0; ok && i < 6; i++) ok = read_long(&cursor, end, &values[i]);
    if (!ok || values[2] <= 0 || values[3] <= 0 || (values[4] != 0 && values[4] != 1) || values[5] < 0 ||
        values[5] > ANVIL_SHELL_STATE_MAX_PATH || values[5] >= end - cursor || cursor[values[5]] != '\n' ||
        memchr(cursor, '\0', (size_t)values[5]))
      break;
    AnvilShellWindowState *window = &state->windows[state->count];
    window->x = values[0];
    window->y = values[1];
    window->w = values[2];
    window->h = values[3];
    window->maximized = values[4] == 1;
    if (values[5]) {
      window->path = malloc((size_t)values[5] + 1);
      if (!window->path) break;
      memcpy(window->path, cursor, (size_t)values[5]);
      window->path[values[5]] = 0;
    }
    state->count++;
    cursor += values[5] + 1;
    complete = true;
  }
  /* A partial or malformed file restores nothing. */
  if (complete) return true;
  anvil_shell_state_free(state);
  return false;
}

static bool write_file(const wchar_t *file, const char *data, size_t size) {
  wchar_t temp[MAX_PATH * 4];
  if (_snwprintf(temp, SDL_arraysize(temp), L"%ls.tmp", file) < 0) return false;
  temp[SDL_arraysize(temp) - 1] = 0;
  HANDLE handle = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (handle == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = WriteFile(handle, data, (DWORD)size, &written, NULL) && written == size && FlushFileBuffers(handle);
  CloseHandle(handle);
  ok = ok && MoveFileExW(temp, file, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  if (!ok) DeleteFileW(temp);
  return ok;
}

bool anvil_shell_state_load(const wchar_t *file, AnvilShellState *state) {
  state->windows = NULL;
  state->count = 0;
  HANDLE handle = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (handle == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size;
  char *data = NULL;
  DWORD read = 0;
  bool ok = GetFileSizeEx(handle, &size) && size.QuadPart <= ANVIL_SHELL_STATE_MAX_BYTES &&
            (data = malloc((size_t)size.QuadPart + 1)) &&
            ReadFile(handle, data, (DWORD)size.QuadPart, &read, NULL) && read == size.QuadPart;
  CloseHandle(handle);
  ok = ok && anvil_shell_state_decode(data, read, state);
  free(data);
  return ok;
}

static struct {
  SDL_Mutex *lock;
  SDL_Condition *wake;
  SDL_Semaphore *done;
  SDL_Thread *thread;
  wchar_t *file;
  char *pending;
  size_t pending_size;
  bool stop;
} writer;

static int SDLCALL writer_thread(void *data) {
  (void)data;
  SDL_LockMutex(writer.lock);
  for (;;) {
    while (!writer.pending && !writer.stop) SDL_WaitCondition(writer.wake, writer.lock);
    char *pending = writer.pending;
    size_t size = writer.pending_size;
    writer.pending = NULL;
    if (!pending) break;
    SDL_UnlockMutex(writer.lock);
    if (!write_file(writer.file, pending, size))
      SDL_Log("Shell Window state write failed: Windows error=%lu", (unsigned long)GetLastError());
    else
      SDL_Log("Shell Window state written: bytes=%lu", (unsigned long)size);
    free(pending);
    SDL_LockMutex(writer.lock);
  }
  SDL_UnlockMutex(writer.lock);
  SDL_SignalSemaphore(writer.done);
  return 0;
}

bool anvil_shell_state_writer_start(const wchar_t *file) {
  if (writer.thread) return true;
  writer.file = _wcsdup(file);
  writer.lock = SDL_CreateMutex();
  writer.wake = SDL_CreateCondition();
  writer.done = SDL_CreateSemaphore(0);
  if (!writer.file || !writer.lock || !writer.wake || !writer.done) return false;
  writer.thread = SDL_CreateThread(writer_thread, "anvil-shell-state", NULL);
  return writer.thread != NULL;
}

void anvil_shell_state_submit(char *data, size_t size) {
  if (!writer.thread || !data) { free(data); return; }
  SDL_LockMutex(writer.lock);
  free(writer.pending);
  writer.pending = data;
  writer.pending_size = size;
  SDL_SignalCondition(writer.wake);
  SDL_UnlockMutex(writer.lock);
}

bool anvil_shell_state_writer_stop(uint32_t timeout_ms) {
  if (!writer.thread) return true;
  SDL_LockMutex(writer.lock);
  writer.stop = true;
  SDL_SignalCondition(writer.wake);
  SDL_UnlockMutex(writer.lock);
  if (!SDL_WaitSemaphoreTimeout(writer.done, (Sint32)timeout_ms)) {
    SDL_Log("Shell Window state write exceeded its shutdown deadline");
    SDL_DetachThread(writer.thread);
    writer.thread = NULL;
    return false;
  }
  SDL_WaitThread(writer.thread, NULL);
  writer.thread = NULL;
  return true;
}
#endif
