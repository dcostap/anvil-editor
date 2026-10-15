#ifdef _WIN32
#include "shell_state.h"
#include <SDL3/SDL.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STATE_HEADER "anvil-shell-windows 3\n"
/* Version 2 had no Project activity. Its Windows still restore. */
#define STATE_HEADER_2 "anvil-shell-windows 2\n"

/* Each Window is one line: `window <id> <x> <y> <w> <h> <maximized> <path bytes> <path>`.
 * Each Project activity is one line: `project <unix seconds> <path bytes> <path>`. */
char *anvil_shell_state_encode(const AnvilShellState *state, size_t *size) {
  if (state->count > ANVIL_SHELL_STATE_MAX_WINDOWS) return NULL;
  size_t capacity = sizeof(STATE_HEADER);
  for (size_t i = 0; i < state->count; i++) {
    size_t length = state->windows[i].path ? strlen(state->windows[i].path) : 0;
    if (length > ANVIL_SHELL_STATE_MAX_PATH) return NULL;
    capacity += length + 96;
  }
  if (capacity > ANVIL_SHELL_STATE_MAX_BYTES) return NULL;
  /* Project activity is best effort. Entries that do not fit are left out; Windows always fit. */
  size_t projects = 0;
  for (size_t i = 0; i < state->project_count && projects < ANVIL_SHELL_STATE_MAX_PROJECTS; i++, projects++) {
    size_t length = strlen(state->projects[i].path);
    if (length > ANVIL_SHELL_STATE_MAX_PATH || capacity + length + 48 > ANVIL_SHELL_STATE_MAX_BYTES) break;
    capacity += length + 48;
  }
  char *data = malloc(capacity);
  if (!data) return NULL;
  size_t n = (size_t)snprintf(data, capacity, "%s", STATE_HEADER);
  for (size_t i = 0; i < state->count; i++) {
    const AnvilShellWindowState *window = &state->windows[i];
    const char *path = window->path ? window->path : "";
    n += (size_t)snprintf(data + n, capacity - n, "window %lu %ld %ld %ld %ld %d %zu %s\n",
                          (unsigned long)window->id, (long)window->x, (long)window->y, (long)window->w, (long)window->h, window->maximized ? 1 : 0,
                          strlen(path), path);
  }
  for (size_t i = 0; i < projects; i++) {
    const AnvilShellProjectActivity *project = &state->projects[i];
    n += (size_t)snprintf(data + n, capacity - n, "project %ld %zu %s\n", (long)project->activity,
                          strlen(project->path), project->path);
  }
  *size = n;
  return data;
}

void anvil_shell_state_free(AnvilShellState *state) {
  for (size_t i = 0; i < state->count; i++) free(state->windows[i].path);
  free(state->windows);
  state->windows = NULL;
  state->count = 0;
  for (size_t i = 0; i < state->project_count; i++) free(state->projects[i].path);
  free(state->projects);
  state->projects = NULL;
  state->project_count = 0;
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

/* Reads `<path bytes> <path>\n` into a new string. */
static bool read_path(const char **cursor, const char *end, long length, char **path) {
  if (length < 0 || length > ANVIL_SHELL_STATE_MAX_PATH || length >= end - *cursor || (*cursor)[length] != '\n' ||
      memchr(*cursor, '\0', (size_t)length))
    return false;
  *path = NULL;
  if (length) {
    *path = malloc((size_t)length + 1);
    if (!*path) return false;
    memcpy(*path, *cursor, (size_t)length);
    (*path)[length] = 0;
  }
  *cursor += length + 1;
  return true;
}

bool anvil_shell_state_decode(const char *data, size_t size, AnvilShellState *state) {
  *state = (AnvilShellState){0};
  size_t header = strlen(STATE_HEADER);
  bool version_2 = size >= header && !memcmp(data, STATE_HEADER_2, header);
  if (size > ANVIL_SHELL_STATE_MAX_BYTES || size < header || (memcmp(data, STATE_HEADER, header) && !version_2))
    return false;
  const char *cursor = data + header, *end = data + size;
  state->windows = calloc(ANVIL_SHELL_STATE_MAX_WINDOWS, sizeof(*state->windows));
  state->projects = version_2 ? NULL : calloc(ANVIL_SHELL_STATE_MAX_PROJECTS, sizeof(*state->projects));
  if (!state->windows || (!version_2 && !state->projects)) {
    anvil_shell_state_free(state);
    return false;
  }
  bool complete = true;
  while (cursor < end) {
    long values[7];
    complete = false;
    if (!version_2 && end - cursor >= 8 && !memcmp(cursor, "project ", 8)) {
      cursor += 8;
      long activity, length;
      AnvilShellProjectActivity *project = &state->projects[state->project_count];
      if (state->project_count >= ANVIL_SHELL_STATE_MAX_PROJECTS || !read_long(&cursor, end, &activity) ||
          activity <= 0 || !read_long(&cursor, end, &length) || length == 0 ||
          !read_path(&cursor, end, length, &project->path))
        break;
      project->activity = activity;
      state->project_count++;
      complete = true;
      continue;
    }
    if (state->count >= ANVIL_SHELL_STATE_MAX_WINDOWS || end - cursor < 7 || memcmp(cursor, "window ", 7)) break;
    cursor += 7;
    bool ok = true;
    for (int i = 0; ok && i < 7; i++) ok = read_long(&cursor, end, &values[i]);
    AnvilShellWindowState *window = &state->windows[state->count];
    if (!ok || values[0] <= 0 || values[3] <= 0 || values[4] <= 0 || (values[5] != 0 && values[5] != 1) ||
        !read_path(&cursor, end, values[6], &window->path))
      break;
    window->id = (uint32_t)values[0];
    window->x = values[1];
    window->y = values[2];
    window->w = values[3];
    window->h = values[4];
    window->maximized = values[5] == 1;
    state->count++;
    complete = true;
  }
  /* A partial or malformed file restores nothing. */
  if (complete) return true;
  anvil_shell_state_free(state);
  return false;
}

bool anvil_shell_file_replace(const wchar_t *file, const char *data, size_t size) {
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

char *anvil_shell_file_read(const wchar_t *file, size_t limit, size_t *size) {
  HANDLE handle = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, NULL);
  if (handle == INVALID_HANDLE_VALUE) return NULL;
  LARGE_INTEGER length;
  char *data = NULL;
  DWORD read = 0;
  bool ok = GetFileSizeEx(handle, &length) && (uint64_t)length.QuadPart <= limit &&
            (data = malloc((size_t)length.QuadPart + 1)) &&
            ReadFile(handle, data, (DWORD)length.QuadPart, &read, NULL) && read == length.QuadPart;
  CloseHandle(handle);
  if (!ok) {
    free(data);
    return NULL;
  }
  data[read] = 0;
  *size = read;
  return data;
}

bool anvil_shell_state_load(const wchar_t *file, AnvilShellState *state) {
  *state = (AnvilShellState){0};
  size_t size = 0;
  char *data = anvil_shell_file_read(file, ANVIL_SHELL_STATE_MAX_BYTES, &size);
  bool ok = data && anvil_shell_state_decode(data, size, state);
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
    if (!anvil_shell_file_replace(writer.file, pending, size))
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
